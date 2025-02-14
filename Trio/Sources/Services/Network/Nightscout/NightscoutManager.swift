import Combine
import CoreData
import Foundation
import LoopKitUI
import Swinject
import UIKit

protocol NightscoutManager: GlucoseSource {
    func fetchGlucose(since date: Date) async -> [BloodGlucose]
    func fetchCarbs() async -> [CarbsEntry]
    func fetchTempTargets() async -> [TempTarget]
    func deleteCarbs(withID id: String) async
    func deleteInsulin(withID id: String) async
    func deleteManualGlucose(withID id: String) async
    func uploadDeviceStatus() async
    func uploadGlucose() async
    func uploadCarbs() async
    func uploadPumpHistory() async
    func uploadOverrides() async
    func uploadTempTargets() async
    func uploadManualGlucose() async
    func uploadProfiles() async
    func uploadNoteTreatment(note: String) async
    func importSettings() async -> ScheduledNightscoutProfile?
    var cgmURL: URL? { get }
}

final class BaseNightscoutManager: NightscoutManager, Injectable {
    @Injected() private var keychain: Keychain!
    @Injected() private var determinationStorage: DeterminationStorage!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var overridesStorage: OverrideStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var pumpHistoryStorage: PumpHistoryStorage!
    @Injected() private var storage: FileStorage!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var reachabilityManager: ReachabilityManager!
    @Injected() var healthkitManager: HealthKitManager!

    private let orefDeterminationSubject = PassthroughSubject<Void, Never>()
    private let uploadOverridesSubject = PassthroughSubject<Void, Never>()
    private let uploadPumpHistorySubject = PassthroughSubject<Void, Never>()
    private let uploadCarbsSubject = PassthroughSubject<Void, Never>()
    private let processQueue = DispatchQueue(label: "BaseNetworkManager.processQueue")
    private var ping: TimeInterval?

    private var backgroundContext = CoreDataStack.shared.newTaskContext()

    private var lifetime = Lifetime()

    private var isNetworkReachable: Bool {
        reachabilityManager.isReachable
    }

    private var isUploadEnabled: Bool {
        settingsManager.settings.isUploadEnabled
    }

    private var isDownloadEnabled: Bool {
        settingsManager.settings.isDownloadEnabled
    }

    private var isUploadGlucoseEnabled: Bool {
        settingsManager.settings.uploadGlucose
    }

    private var nightscoutAPI: NightscoutAPI? {
        guard let urlString = keychain.getValue(String.self, forKey: NightscoutConfig.Config.urlKey),
              let url = URL(string: urlString),
              let secret = keychain.getValue(String.self, forKey: NightscoutConfig.Config.secretKey)
        else {
            return nil
        }
        return NightscoutAPI(url: url, secret: secret)
    }

    private var lastEnactedDetermination: Determination?
    private var lastSuggestedDetermination: Determination?

    // Queue for handling Core Data change notifications
    private let queue = DispatchQueue(label: "BaseNightscoutManager.queue", qos: .background)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        subscribe()

        coreDataPublisher =
            changedObjectsOnManagedObjectContextDidSavePublisher()
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        registerSubscribers()
        registerHandlers()
        setupNotification()

        /// Ensure that Nightscout Manager holds the `lastEnactedDetermination`, if one exists, on initialization.
        /// We have to set this here in `init()`, so there's a `lastEnactedDetermination` available after an app restart
        /// for `uploadDeviceStatus()`, as within that fuction `lastEnactedDetermination` is reassigned at the very end of the function.
        /// This way, we ensure the latest enacted determination is always part of `devicestatus` and avoid having instances
        /// where the first uploaded non-enacted determination (i.e., "suggested"), lacks the "enacted" data.
        Task {
            async let lastEnactedDeterminationID = determinationStorage
                .fetchLastDeterminationObjectID(predicate: NSPredicate.enactedDetermination)

            self.lastEnactedDetermination = await determinationStorage
                .getOrefDeterminationNotYetUploadedToNightscout(lastEnactedDeterminationID)
        }
    }

    private func subscribe() {
        _ = reachabilityManager.startListening(onQueue: processQueue) { status in
            debug(.nightscout, "Network status: \(status)")
        }
    }

    private func registerHandlers() {
        coreDataPublisher?
            .filterByEntityName("OrefDetermination")
            .sink { [weak self] objectIDs in
                guard let self = self else { return }

                // Now hop onto the background context's queue
                self.backgroundContext.perform {
                    do {
                        // Fetch only those determination objects
                        let request: NSFetchRequest<OrefDetermination> = OrefDetermination.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "SELF IN %@ AND isUploadedToNS == NO",
                            objectIDs
                        )
                        let results = try self.backgroundContext.fetch(request)

                        // If valid, proceed to send to subject for further processing
                        if !results.isEmpty {
                            self.orefDeterminationSubject.send()
                        }
                    } catch {
                        debugPrint("Failed to fetch OrefDetermination objects: \(error)")
                    }
                }
            }
            .store(in: &subscriptions)

        coreDataPublisher?.filterByEntityName("OverrideStored").sink { [weak self] _ in
            self?.uploadOverridesSubject.send()
        }.store(in: &subscriptions)

        coreDataPublisher?.filterByEntityName("OverrideRunStored").sink { [weak self] _ in
            self?.uploadOverridesSubject.send()
        }.store(in: &subscriptions)

        coreDataPublisher?.filterByEntityName("TempTargetStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task.detached {
                await self.uploadTempTargets()
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filterByEntityName("TempTargetRunStored").sink { [weak self] _ in
            guard let self = self else { return }
            Task.detached {
                await self.uploadTempTargets()
            }
        }.store(in: &subscriptions)

        coreDataPublisher?.filterByEntityName("PumpEventStored")
            .sink { [weak self] objectIDs in
                guard let self = self else { return }

                self.backgroundContext.perform {
                    do {
                        let request: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "SELF IN %@ AND isUploadedToNS == NO",
                            objectIDs
                        )
                        let results = try self.backgroundContext.fetch(request)

                        if !results.isEmpty {
                            self.uploadPumpHistorySubject.send()
                        }
                    } catch {
                        debugPrint("Failed to fetch PumpEventStored objects: \(error)")
                    }
                }
            }
            .store(in: &subscriptions)

        coreDataPublisher?.filterByEntityName("CarbEntryStored")
            .sink { [weak self] objectIDs in
                guard let self = self else { return }

                // Now hop onto the background context’s queue
                self.backgroundContext.perform {
                    do {
                        let request: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
                        request.predicate = NSPredicate(
                            format: "SELF IN %@ AND isUploadedToNS == NO",
                            objectIDs
                        )
                        let results = try self.backgroundContext.fetch(request)

                        // If valid, proceed to send to subject for further processing
                        if !results.isEmpty {
                            self.uploadCarbsSubject.send()
                        }
                    } catch {
                        debugPrint("Failed to fetch CarbEntryStored objects: \(error)")
                    }
                }
            }
            .store(in: &subscriptions)

        coreDataPublisher?.filterByEntityName("GlucoseStored")
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task.detached {
                    await self.uploadGlucose()
                    await self.uploadManualGlucose()
                }
            }
            .store(in: &subscriptions)
    }

    func registerSubscribers() {
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.uploadGlucose()
                }
            }
            .store(in: &subscriptions)

        /// We add debouncing behavior here for two main reasons
        /// 1. To ensure that any upload flag updates have properly been performed, and in subsequent fetching processes only truly unuploaded data is fetched
        /// 2. To not spam the user's NS site with a high number of uploads in a very short amount of time (less than 1sec)
        orefDeterminationSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .background))
            .sink { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.uploadDeviceStatus()
                }
            }
            .store(in: &subscriptions)

        uploadOverridesSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .background))
            .sink { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.uploadOverrides()
                }
            }
            .store(in: &subscriptions)

        uploadPumpHistorySubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .background))
            .sink { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.uploadPumpHistory()
                }
            }
            .store(in: &subscriptions)

        uploadCarbsSubject
            .debounce(for: .seconds(2), scheduler: DispatchQueue.global(qos: .background))
            .sink { [weak self] in
                guard let self = self else { return }
                Task {
                    await self.uploadCarbs()
                }
            }
            .store(in: &subscriptions)
    }

    func setupNotification() {
        Foundation.NotificationCenter.default.publisher(for: .willUpdateOverrideConfiguration)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.uploadOverrides()

                    // Post a notification indicating that the upload has finished and that we can end the background task in the OverridePresetsIntentRequest
                    Foundation.NotificationCenter.default.post(name: .didUpdateOverrideConfiguration, object: nil)
                }
            }
            .store(in: &subscriptions)

        Foundation.NotificationCenter.default.publisher(for: .willUpdateTempTargetConfiguration)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.uploadTempTargets()

                    // Post a notification indicating that the upload has finished and that we can end the background task in the TempTargetPresetsIntentRequest
                    Foundation.NotificationCenter.default.post(name: .didUpdateTempTargetConfiguration, object: nil)
                }
            }
            .store(in: &subscriptions)
    }

    func sourceInfo() -> [String: Any]? {
        if let ping = ping {
            return [GlucoseSourceKey.nightscoutPing.rawValue: ping]
        }
        return nil
    }

    var cgmURL: URL? {
        if let url = settingsManager.settings.cgm.appURL {
            return url
        }

        let useLocal = settingsManager.settings.useLocalGlucoseSource

        let maybeNightscout = useLocal
            ? NightscoutAPI(url: URL(string: "http://127.0.0.1:\(settingsManager.settings.localGlucosePort)")!)
            : nightscoutAPI

        return maybeNightscout?.url
    }

    func fetchGlucose(since date: Date) async -> [BloodGlucose] {
        let useLocal = settingsManager.settings.useLocalGlucoseSource
        ping = nil

        if !useLocal {
            guard isNetworkReachable else {
                return []
            }
        }

        let maybeNightscout = useLocal
            ? NightscoutAPI(url: URL(string: "http://127.0.0.1:\(settingsManager.settings.localGlucosePort)")!)
            : nightscoutAPI

        guard let nightscout = maybeNightscout else {
            return []
        }

        let startDate = Date()

        do {
            let glucose = try await nightscout.fetchLastGlucose(sinceDate: date)
            if glucose.isNotEmpty {
                ping = Date().timeIntervalSince(startDate)
            }
            return glucose
        } catch {
            print(error.localizedDescription)
            return []
        }
    }

    // MARK: - GlucoseSource

    var glucoseManager: FetchGlucoseManager?
    var cgmManager: CGMManagerUI?

    func fetch(_: DispatchTimer?) -> AnyPublisher<[BloodGlucose], Never> {
        Future { promise in
            Task {
                let glucoseData = await self.fetchGlucose(since: self.glucoseStorage.syncDate())
                promise(.success(glucoseData))
            }
        }
        .eraseToAnyPublisher()
    }

    func fetchIfNeeded() -> AnyPublisher<[BloodGlucose], Never> {
        fetch(nil)
    }

    func fetchCarbs() async -> [CarbsEntry] {
        guard let nightscout = nightscoutAPI, isNetworkReachable, isDownloadEnabled else {
            return []
        }

        let since = carbsStorage.syncDate()
        do {
            let carbs = try await nightscout.fetchCarbs(sinceDate: since)
            return carbs
        } catch {
            debug(.nightscout, "Error fetching carbs: \(error.localizedDescription)")
            return []
        }
    }

    func fetchTempTargets() async -> [TempTarget] {
        guard let nightscout = nightscoutAPI, isNetworkReachable, isDownloadEnabled else {
            return []
        }

        let since = tempTargetsStorage.syncDate()
        do {
            let tempTargets = try await nightscout.fetchTempTargets(sinceDate: since)
            return tempTargets
        } catch {
            debug(.nightscout, "Error fetching temp targets: \(error.localizedDescription)")
            return []
        }
    }

    func deleteCarbs(withID id: String) async {
        guard let nightscout = nightscoutAPI, isUploadEnabled else { return }

        do {
            try await nightscout.deleteCarbs(withId: id)
            debug(.nightscout, "Carbs deleted")
        } catch {
            debug(
                .nightscout,
                "\(DebuggingIdentifiers.failed) Failed to delete Carbs from Nightscout with error: \(error.localizedDescription)"
            )
        }
    }

    func deleteInsulin(withID id: String) async {
        guard let nightscout = nightscoutAPI, isUploadEnabled else { return }

        do {
            try await nightscout.deleteInsulin(withId: id)
            debug(.nightscout, "Insulin deleted")
        } catch {
            debug(
                .nightscout,
                "\(DebuggingIdentifiers.failed) Failed to delete Insulin from Nightscout with error: \(error.localizedDescription)"
            )
        }
    }

    func deleteManualGlucose(withID id: String) async {
        guard let nightscout = nightscoutAPI, isUploadEnabled else { return }

        do {
            try await nightscout.deleteManualGlucose(withId: id)
        } catch {
            debug(
                .nightscout,
                "\(DebuggingIdentifiers.failed) Failed to delete Manual Glucose from Nightscout with error: \(error.localizedDescription)"
            )
        }
    }

    private func fetchBattery() async -> Battery {
        await backgroundContext.perform {
            do {
                let results = try self.backgroundContext.fetch(OpenAPS_Battery.fetch(NSPredicate.predicateFor30MinAgo))
                if let last = results.first {
                    let percent: Int? = Int(last.percent)
                    let voltage: Decimal? = last.voltage as Decimal?
                    let status: String? = last.status
                    let display: Bool? = last.display

                    if let status {
                        debugPrint(
                            "NightscoutManager: \(#function) \(DebuggingIdentifiers.succeeded) setup battery from core data successfully"
                        )
                        return Battery(
                            percent: percent,
                            voltage: voltage,
                            string: BatteryState(rawValue: status) ?? BatteryState.unknown,
                            display: display
                        )
                    }
                }
                debugPrint(
                    "NightscoutManager: \(#function) \(DebuggingIdentifiers.succeeded) successfully fetched; but no battery data available. Returning fallback default."
                )
                return Battery(percent: nil, voltage: nil, string: BatteryState.error, display: nil)
            } catch {
                debugPrint(
                    "NightscoutManager: \(#function) \(DebuggingIdentifiers.failed) failed to setup battery from core data"
                )
                return Battery(percent: nil, voltage: nil, string: BatteryState.error, display: nil)
            }
        }
    }

    /// Asynchronously uploads the current status to Nightscout, including OpenAPS status, pump status, and uploader details.
    ///
    /// This function gathers and processes various pieces of information such as the "enacted" and "suggested" determinations,
    /// pump battery and reservoir levels, insulin-on-board (IOB), and the uploader's battery status. It ensures that only
    /// valid determinations are uploaded by filtering out duplicates and handling unit conversions based on the user's
    /// settings. If the status upload is successful, it updates the determination storage to mark them as uploaded.
    ///
    /// Key steps:
    /// - Fetch the last unuploaded enacted and suggested determinations from the storage.
    /// - Retrieve pump-related data such as battery, reservoir, and status.
    /// - Parse determinations to ensure they are properly formatted for Nightscout, including unit conversions if needed.
    /// - Construct an `OpenAPSStatus` object with relevant information for upload.
    /// - Construct a `NightscoutStatus` object with all gathered data.
    /// - Attempt to upload the status to Nightscout. On success, update the storage to mark determinations as uploaded.
    /// - Schedule a task to upload pod age data separately.
    ///
    /// - Note: Ensure `nightscoutAPI` is initialized and `isUploadEnabled` is set to `true` before invoking this function.
    /// - Returns: Nothing.
    func uploadDeviceStatus() async {
        guard let nightscout = nightscoutAPI, isUploadEnabled else {
            debug(.nightscout, "NS API not available or upload disabled. Aborting NS Status upload.")
            return
        }

        // Suggested / Enacted
        async let enactedDeterminationID = determinationStorage
            .fetchLastDeterminationObjectID(predicate: NSPredicate.enactedDeterminationsNotYetUploadedToNightscout)
        async let suggestedDeterminationID = determinationStorage
            .fetchLastDeterminationObjectID(predicate: NSPredicate.suggestedDeterminationsNotYetUploadedToNightscout)

        // OpenAPS Status
        async let fetchedBattery = fetchBattery()
        async let fetchedReservoir = Decimal(from: storage.retrieveRawAsync(OpenAPS.Monitor.reservoir) ?? "0")
        async let fetchedIOBEntry = storage.retrieveAsync(OpenAPS.Monitor.iob, as: [IOBEntry].self)
        async let fetchedPumpStatus = storage.retrieveAsync(OpenAPS.Monitor.status, as: PumpStatus.self)

        var (fetchedEnactedDetermination, fetchedSuggestedDetermination) = await (
            determinationStorage.getOrefDeterminationNotYetUploadedToNightscout(enactedDeterminationID),
            determinationStorage.getOrefDeterminationNotYetUploadedToNightscout(suggestedDeterminationID)
        )

        // Guard to ensure both determinations are not nil
        guard fetchedEnactedDetermination != nil || fetchedSuggestedDetermination != nil else {
            debug(
                .nightscout,
                "Both fetchedEnactedDetermination and fetchedSuggestedDetermination are nil. Aborting NS Status upload."
            )
            return
        }

        // Unwrap fetchedSuggestedDetermination and manipulate the timestamp field to ensure deliverAt and timestamp for a suggestion truly match!
        var modifiedSuggestedDetermination = fetchedSuggestedDetermination
        if var suggestion = fetchedSuggestedDetermination {
            suggestion.timestamp = suggestion.deliverAt

            if settingsManager.settings.units == .mmolL {
                suggestion.reason = parseReasonGlucoseValuesToMmolL(suggestion.reason)
                // TODO: verify that these parsings are needed for 3rd party apps, e.g., LoopFollow
                suggestion.current_target = suggestion.current_target?.asMmolL
                suggestion.minGuardBG = suggestion.minGuardBG?.asMmolL
                suggestion.minPredBG = suggestion.minPredBG?.asMmolL
                suggestion.threshold = suggestion.threshold?.asMmolL
            }
            // Check whether the last suggestion that was uploaded is the same that is fetched again when we are attempting to upload the enacted determination
            // Apparently we are too fast; so the flag update is not fast enough to have the predicate filter last suggestion out
            // If this check is truthy, set suggestion to nil so it's not uploaded again
            if let lastSuggested = lastSuggestedDetermination, lastSuggested.deliverAt == suggestion.deliverAt {
                modifiedSuggestedDetermination = nil
            } else {
                modifiedSuggestedDetermination = suggestion
            }
        }

        if let fetchedEnacted = fetchedEnactedDetermination, settingsManager.settings.units == .mmolL {
            var modifiedFetchedEnactedDetermination = fetchedEnactedDetermination
            modifiedFetchedEnactedDetermination?
                .reason = parseReasonGlucoseValuesToMmolL(fetchedEnacted.reason)
            // TODO: verify that these parsings are needed for 3rd party apps, e.g., LoopFollow
            modifiedFetchedEnactedDetermination?.current_target = fetchedEnacted.current_target?.asMmolL
            modifiedFetchedEnactedDetermination?.minGuardBG = fetchedEnacted.minGuardBG?.asMmolL
            modifiedFetchedEnactedDetermination?.minPredBG = fetchedEnacted.minPredBG?.asMmolL
            modifiedFetchedEnactedDetermination?.threshold = fetchedEnacted.threshold?.asMmolL

            fetchedEnactedDetermination = modifiedFetchedEnactedDetermination
        }

        // Gather all relevant data for OpenAPS Status
        let iob = await fetchedIOBEntry

        let suggestedToUpload = modifiedSuggestedDetermination ?? lastSuggestedDetermination
        let enactedToUpload = fetchedEnactedDetermination ?? lastEnactedDetermination

        let openapsStatus = OpenAPSStatus(
            iob: iob?.first,
            suggested: suggestedToUpload,
            enacted: settingsManager.settings.closedLoop ? enactedToUpload : nil,
            version: Bundle.main.releaseVersionNumber ?? "Unknown"
        )

        debug(.nightscout, "To be uploaded openapsStatus: \(openapsStatus)")

        // Gather all relevant data for NS Status
        let battery = await fetchedBattery
        let reservoir = await fetchedReservoir
        let pumpStatus = await fetchedPumpStatus
        let pump = NSPumpStatus(
            clock: Date(),
            battery: battery,
            reservoir: reservoir != 0xDEAD_BEEF ? reservoir : nil,
            status: pumpStatus
        )

        let batteryLevel = await UIDevice.current.batteryLevel
        let batteryState = await UIDevice.current.batteryState
        let uploader = Uploader(
            batteryVoltage: nil,
            battery: Int(batteryLevel * 100),
            isCharging: batteryState == .charging || batteryState == .full
        )
        let status = NightscoutStatus(
            device: NightscoutTreatment.local,
            openaps: openapsStatus,
            pump: pump,
            uploader: uploader
        )

        do {
            try await nightscout.uploadDeviceStatus(status)
            debug(.nightscout, "NSDeviceStatus with Determination uploaded")

            if let enacted = fetchedEnactedDetermination {
                await updateOrefDeterminationAsUploaded([enacted])
                debug(.nightscout, "Flagged last fetched enacted determination as uploaded")
            }

            if let suggested = fetchedSuggestedDetermination {
                await updateOrefDeterminationAsUploaded([suggested])
                debug(.nightscout, "Flagged last fetched suggested determination as uploaded")
            }

            if let lastEnactedDetermination = fetchedEnactedDetermination {
                self.lastEnactedDetermination = lastEnactedDetermination
            }

            if let lastSuggestedDetermination = fetchedSuggestedDetermination {
                self.lastSuggestedDetermination = lastSuggestedDetermination
            }
        } catch {
            debug(.nightscout, error.localizedDescription)
        }

        Task.detached {
            await self.uploadPodAge()
        }
    }

    private func updateOrefDeterminationAsUploaded(_ determination: [Determination]) async {
        await backgroundContext.perform {
            let ids = determination.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<OrefDetermination> = OrefDetermination.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS: \(error.userInfo)"
                )
            }
        }
    }

    func uploadPodAge() async {
        let uploadedPodAge = storage.retrieve(OpenAPS.Nightscout.uploadedPodAge, as: [NightscoutTreatment].self) ?? []
        if let podAge = storage.retrieve(OpenAPS.Monitor.podAge, as: Date.self),
           uploadedPodAge.last?.createdAt == nil || podAge != uploadedPodAge.last!.createdAt!
        {
            let siteTreatment = NightscoutTreatment(
                duration: nil,
                rawDuration: nil,
                rawRate: nil,
                absolute: nil,
                rate: nil,
                eventType: .nsSiteChange,
                createdAt: podAge,
                enteredBy: NightscoutTreatment.local,
                bolus: nil,
                insulin: nil,
                notes: nil,
                carbs: nil,
                fat: nil,
                protein: nil,
                targetTop: nil,
                targetBottom: nil
            )
            await uploadNonCoreDataTreatments([siteTreatment])
        }
    }

    func uploadProfiles() async {
        if isUploadEnabled {
            do {
                guard let sensitivities = await storage.retrieveAsync(
                    OpenAPS.Settings.insulinSensitivities,
                    as: InsulinSensitivities.self
                ) else {
                    debug(.nightscout, "NightscoutManager uploadProfile: error loading insulinSensitivities")
                    return
                }
                guard let targets = await storage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self) else {
                    debug(.nightscout, "NightscoutManager uploadProfile: error loading bgTargets")
                    return
                }
                guard let carbRatios = await storage.retrieveAsync(OpenAPS.Settings.carbRatios, as: CarbRatios.self) else {
                    debug(.nightscout, "NightscoutManager uploadProfile: error loading carbRatios")
                    return
                }
                guard let basalProfile = await storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self)
                else {
                    debug(.nightscout, "NightscoutManager uploadProfile: error loading basalProfile")
                    return
                }

                let shouldParseToMmolL = settingsManager.settings.units == .mmolL

                let sens = sensitivities.sensitivities.map { item in
                    NightscoutTimevalue(
                        time: String(item.start.prefix(5)),
                        value: !shouldParseToMmolL ? item.sensitivity : item.sensitivity.asMmolL,
                        timeAsSeconds: item.offset * 60
                    )
                }
                let targetLow = targets.targets.map { item in
                    NightscoutTimevalue(
                        time: String(item.start.prefix(5)),
                        value: !shouldParseToMmolL ? item.low : item.low.asMmolL,
                        timeAsSeconds: item.offset * 60
                    )
                }
                let targetHigh = targets.targets.map { item in
                    NightscoutTimevalue(
                        time: String(item.start.prefix(5)),
                        value: !shouldParseToMmolL ? item.high : item.high.asMmolL,
                        timeAsSeconds: item.offset * 60
                    )
                }
                let cr = carbRatios.schedule.map { item in
                    NightscoutTimevalue(
                        time: String(item.start.prefix(5)),
                        value: item.ratio,
                        timeAsSeconds: item.offset * 60
                    )
                }
                let basal = basalProfile.map { item in
                    NightscoutTimevalue(
                        time: String(item.start.prefix(5)),
                        value: item.rate,
                        timeAsSeconds: item.minutes * 60
                    )
                }

                let nsUnits: String = {
                    switch settingsManager.settings.units {
                    case .mgdL:
                        return "mg/dl"
                    case .mmolL:
                        return "mmol"
                    }
                }()

                var carbsHr: Decimal = 0
                if let isf = sensitivities.sensitivities.map(\.sensitivity).first,
                   let cr = carbRatios.schedule.map(\.ratio).first,
                   isf > 0, cr > 0
                {
                    carbsHr = settingsManager.preferences.min5mCarbimpact * 12 / isf * cr
                    if settingsManager.settings.units == .mmolL {
                        carbsHr *= GlucoseUnits.exchangeRate
                    }
                    carbsHr = Decimal(round(Double(carbsHr) * 10.0)) / 10
                }

                let scheduledProfile = ScheduledNightscoutProfile(
                    dia: settingsManager.pumpSettings.insulinActionCurve,
                    carbs_hr: Int(carbsHr),
                    delay: 0,
                    timezone: TimeZone.current.identifier,
                    target_low: targetLow,
                    target_high: targetHigh,
                    sens: sens,
                    basal: basal,
                    carbratio: cr,
                    units: nsUnits
                )
                let defaultProfile = "default"

                let now = Date()

                let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
                let deviceToken = UserDefaults.standard.string(forKey: "deviceToken") ?? ""
                let isAPNSProduction = UserDefaults.standard.bool(forKey: "isAPNSProduction")
                let presetOverrides = await overridesStorage.getPresetOverridesForNightscout()
                let teamID = Bundle.main.object(forInfoDictionaryKey: "TeamID") as? String ?? ""

                let profileStore = NightscoutProfileStore(
                    defaultProfile: defaultProfile,
                    startDate: now,
                    mills: Int(now.timeIntervalSince1970) * 1000,
                    units: nsUnits,
                    enteredBy: NightscoutTreatment.local,
                    store: [defaultProfile: scheduledProfile],
                    bundleIdentifier: bundleIdentifier,
                    deviceToken: deviceToken,
                    isAPNSProduction: isAPNSProduction,
                    overridePresets: presetOverrides,
                    teamID: teamID
                )

                guard let nightscout = nightscoutAPI, isNetworkReachable else {
                    if !isNetworkReachable {
                        debug(.nightscout, "Network issues; aborting upload")
                    }
                    debug(.nightscout, "Nightscout API service not available; aborting upload")
                    return
                }

                do {
                    try await nightscout.uploadProfile(profileStore)
                    debug(.nightscout, "Profile uploaded")
                } catch {
                    debug(.nightscout, "NightscoutManager uploadProfile: \(error.localizedDescription)")
                }
            }
        } else {
            debug(.nightscout, "Upload to NS disabled; aborting profile uploaded")
        }
    }

    func importSettings() async -> ScheduledNightscoutProfile? {
        guard let nightscout = nightscoutAPI else {
            debug(.nightscout, "NS API not available. Aborting NS Status upload.")
            return nil
        }

        do {
            return try await nightscout.importSettings()
        } catch {
            debug(.nightscout, error.localizedDescription)
            return nil
        }
    }

    func uploadGlucose() async {
        await uploadGlucose(glucoseStorage.getGlucoseNotYetUploadedToNightscout())
        await uploadNonCoreDataTreatments(glucoseStorage.getCGMStateNotYetUploadedToNightscout())
    }

    func uploadManualGlucose() async {
        await uploadManualGlucose(glucoseStorage.getManualGlucoseNotYetUploadedToNightscout())
    }

    func uploadPumpHistory() async {
        await uploadPumpHistory(pumpHistoryStorage.getPumpHistoryNotYetUploadedToNightscout())
    }

    func uploadCarbs() async {
        await uploadCarbs(carbsStorage.getCarbsNotYetUploadedToNightscout())
        await uploadCarbs(carbsStorage.getFPUsNotYetUploadedToNightscout())
    }

    func uploadOverrides() async {
        await uploadOverrides(overridesStorage.getOverridesNotYetUploadedToNightscout())
        await uploadOverrideRuns(overridesStorage.getOverrideRunsNotYetUploadedToNightscout())
    }

    func uploadTempTargets() async {
        await uploadTempTargets(await tempTargetsStorage.getTempTargetsNotYetUploadedToNightscout())
        await uploadTempTargetRuns(await tempTargetsStorage.getTempTargetRunsNotYetUploadedToNightscout())
    }

    private func uploadGlucose(_ glucose: [BloodGlucose]) async {
        guard !glucose.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled, isUploadGlucoseEnabled else {
            return
        }

        do {
            // Upload in Batches of 100
            for chunk in glucose.chunks(ofCount: 100) {
                try await nightscout.uploadGlucose(Array(chunk))
            }

            // If successful, update the isUploadedToNS property of the GlucoseStored objects
            await updateGlucoseAsUploaded(glucose)

            debug(.nightscout, "Glucose uploaded")
        } catch {
            debug(.nightscout, "Upload of glucose failed: \(error.localizedDescription)")
        }
    }

    private func updateGlucoseAsUploaded(_ glucose: [BloodGlucose]) async {
        await backgroundContext.perform {
            let ids = glucose.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS: \(error.userInfo)"
                )
            }
        }
    }

    private func uploadNonCoreDataTreatments(_ treatments: [NightscoutTreatment]) async {
        guard !treatments.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in treatments.chunks(ofCount: 100) {
                try await nightscout.uploadTreatments(Array(chunk))
            }

            debug(.nightscout, "Treatments uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func uploadPumpHistory(_ treatments: [NightscoutTreatment]) async {
        guard !treatments.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in treatments.chunks(ofCount: 100) {
                try await nightscout.uploadTreatments(Array(chunk))
            }

            await updatePumpEventStoredsAsUploaded(treatments)

            debug(.nightscout, "Treatments uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func updatePumpEventStoredsAsUploaded(_ treatments: [NightscoutTreatment]) async {
        await backgroundContext.perform {
            let ids = treatments.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<PumpEventStored> = PumpEventStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS: \(error.userInfo)"
                )
            }
        }
    }

    private func uploadManualGlucose(_ treatments: [NightscoutTreatment]) async {
        guard !treatments.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in treatments.chunks(ofCount: 100) {
                try await nightscout.uploadTreatments(Array(chunk))
            }

            // If successful, update the isUploadedToNS property of the GlucoseStored objects
            await updateManualGlucoseAsUploaded(treatments)

            debug(.nightscout, "Treatments uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func updateManualGlucoseAsUploaded(_ treatments: [NightscoutTreatment]) async {
        await backgroundContext.perform {
            let ids = treatments.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<GlucoseStored> = GlucoseStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS: \(error.userInfo)"
                )
            }
        }
    }

    private func uploadCarbs(_ treatments: [NightscoutTreatment]) async {
        guard !treatments.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in treatments.chunks(ofCount: 100) {
                try await nightscout.uploadTreatments(Array(chunk))
            }

            // If successful, update the isUploadedToNS property of the CarbEntryStored objects
            await updateCarbsAsUploaded(treatments)

            debug(.nightscout, "Treatments uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func updateCarbsAsUploaded(_ treatments: [NightscoutTreatment]) async {
        await backgroundContext.perform {
            let ids = treatments.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<CarbEntryStored> = CarbEntryStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS: \(error.userInfo)"
                )
            }
        }
    }

    private func uploadOverrides(_ overrides: [NightscoutExercise]) async {
        guard !overrides.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in overrides.chunks(ofCount: 100) {
                try await nightscout.uploadOverrides(Array(chunk))
            }

            // If successful, update the isUploadedToNS property of the OverrideStored objects
            await updateOverridesAsUploaded(overrides)

            debug(.nightscout, "Overrides uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func updateOverridesAsUploaded(_ overrides: [NightscoutExercise]) async {
        await backgroundContext.perform {
            let ids = overrides.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS: \(error.userInfo)"
                )
            }
        }
    }

    private func uploadOverrideRuns(_ overrideRuns: [NightscoutExercise]) async {
        guard !overrideRuns.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in overrideRuns.chunks(ofCount: 100) {
                try await nightscout.uploadOverrides(Array(chunk))
            }

            // If successful, update the isUploadedToNS property of the OverrideRunStored objects
            await updateOverrideRunsAsUploaded(overrideRuns)

            debug(.nightscout, "Overrides uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func updateOverrideRunsAsUploaded(_ overrideRuns: [NightscoutExercise]) async {
        await backgroundContext.perform {
            let ids = overrideRuns.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<OverrideRunStored> = OverrideRunStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS: \(error.userInfo)"
                )
            }
        }
    }

    private func uploadTempTargets(_ tempTargets: [NightscoutTreatment]) async {
        guard !tempTargets.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in tempTargets.chunks(ofCount: 100) {
                try await nightscout.uploadTreatments(Array(chunk))
            }

            // If successful, update the isUploadedToNS property of the TempTargetStored objects
            await updateTempTargetsAsUploaded(tempTargets)

            debug(.nightscout, "Temp Targets uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func updateTempTargetsAsUploaded(_ tempTargets: [NightscoutTreatment]) async {
        await backgroundContext.perform {
            let ids = tempTargets.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<TempTargetStored> = TempTargetStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS for TempTargetStored: \(error.userInfo)"
                )
            }
        }
    }

    private func uploadTempTargetRuns(_ tempTargetRuns: [NightscoutTreatment]) async {
        guard !tempTargetRuns.isEmpty, let nightscout = nightscoutAPI, isUploadEnabled else {
            return
        }

        do {
            for chunk in tempTargetRuns.chunks(ofCount: 100) {
                try await nightscout.uploadTreatments(Array(chunk))
            }

            // If successful, update the isUploadedToNS property of the TempTargetRunStored objects
            await updateTempTargetRunsAsUploaded(tempTargetRuns)

            debug(.nightscout, "Temp Target Runs uploaded")
        } catch {
            debug(.nightscout, error.localizedDescription)
        }
    }

    private func updateTempTargetRunsAsUploaded(_ tempTargetRuns: [NightscoutTreatment]) async {
        await backgroundContext.perform {
            let ids = tempTargetRuns.map(\.id) as NSArray
            let fetchRequest: NSFetchRequest<TempTargetRunStored> = TempTargetRunStored.fetchRequest()
            fetchRequest.predicate = NSPredicate(format: "id IN %@", ids)

            do {
                let results = try self.backgroundContext.fetch(fetchRequest)
                for result in results {
                    result.isUploadedToNS = true
                }

                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            } catch let error as NSError {
                debugPrint(
                    "\(DebuggingIdentifiers.failed) \(#file) \(#function) Failed to update isUploadedToNS for TempTargetRunStored: \(error.userInfo)"
                )
            }
        }
    }

    // TODO: have this checked; this has never actually written anything to file; the entire logic of this function seems broken
    func uploadNoteTreatment(note: String) async {
        let uploadedNotes = storage.retrieve(OpenAPS.Nightscout.uploadedNotes, as: [NightscoutTreatment].self) ?? []
        let now = Date()

        if uploadedNotes.last?.notes != note || (uploadedNotes.last?.createdAt ?? .distantPast) != now {
            let noteTreatment = NightscoutTreatment(
                eventType: .nsNote,
                createdAt: now,
                enteredBy: NightscoutTreatment.local,
                notes: note,
                targetTop: nil,
                targetBottom: nil
            )
            await uploadNonCoreDataTreatments([noteTreatment])
            // TODO: fix/adjust, if necessary
//            await uploadTreatments([noteTreatment], fileToSave: OpenAPS.Nightscout.uploadedNotes)
        }
    }
}

extension Array {
    func chunks(ofCount count: Int) -> [[Element]] {
        stride(from: 0, to: self.count, by: count).map {
            Array(self[$0 ..< Swift.min($0 + count, self.count)])
        }
    }
}

extension BaseNightscoutManager {
    /**
     Converts glucose-related values in the given `reason` string to mmol/L, including ranges (e.g., `ISF: 54→54`), comparisons (e.g., `maxDelta 37 > 20% of BG 95`), and both positive and negative values (e.g., `Dev: -36`).

     - Parameters:
       - reason: The string containing glucose-related values to be converted.

     - Returns:
       A string with glucose values converted to mmol/L.

     - Glucose tags handled: `ISF:`, `Target:`, `minPredBG`, `minGuardBG`, `IOBpredBG`, `COBpredBG`, `UAMpredBG`, `Dev:`, `maxDelta`, `BGI`.
     */

    // TODO: Consolidate all mmol parsing methods (in TagCloudView, NightscoutManager and HomeRootView) to one central func
    func parseReasonGlucoseValuesToMmolL(_ reason: String) -> String {
        let patterns = [
            "ISF:\\s*-?\\d+\\.?\\d*→-?\\d+\\.?\\d*", // ISF with arrow
            "Dev:\\s*-?\\d+\\.?\\d*", // Dev pattern
            "BGI:\\s*-?\\d+\\.?\\d*", // BGI pattern
            "Target:\\s*-?\\d+\\.?\\d*", // Target pattern
            "(?:minPredBG|minGuardBG|IOBpredBG|COBpredBG|UAMpredBG)\\s+-?\\d+\\.?\\d*(?:<-?\\d+\\.?\\d*)?", // minPredBG, etc.
            "minGuardBG\\s+-?\\d+\\.?\\d*<-?\\d+\\.?\\d*", // minGuardBG x<y
            "Eventual BG\\s+-?\\d+\\.?\\d*\\s*>=\\s*-?\\d+\\.?\\d*", // Eventual BG x >= target
            "Eventual BG\\s+-?\\d+\\.?\\d*\\s*<\\s*-?\\d+\\.?\\d*", // Eventual BG x < target
            "\\S+\\s+\\d+\\s*>\\s*\\d+%\\s+of\\s+BG\\s+\\d+" // maxDelta x > y% of BG z
        ]
        let pattern = patterns.joined(separator: "|")
        let regex = try! NSRegularExpression(pattern: pattern)

        func convertToMmolL(_ value: String) -> String {
            if let glucoseValue = Double(value.replacingOccurrences(of: "[^\\d.-]", with: "", options: .regularExpression)) {
                let mmolValue = Decimal(glucoseValue).asMmolL
                return mmolValue.description
            }
            return value
        }

        let matches = regex.matches(in: reason, range: NSRange(reason.startIndex..., in: reason))
        var updatedReason = reason

        for match in matches.reversed() {
            guard let range = Range(match.range, in: reason) else { continue }
            let glucoseValueString = String(reason[range])

            if glucoseValueString.contains("→") {
                // Handle ISF: X→Y
                let values = glucoseValueString.components(separatedBy: "→")
                let firstNumber = values[0].components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)
                let secondNumber = values[1].trimmingCharacters(in: .whitespaces)
                let firstValue = convertToMmolL(firstNumber)
                let secondValue = convertToMmolL(secondNumber)
                let formattedString = "ISF: \(firstValue)→\(secondValue)"
                updatedReason.replaceSubrange(range, with: formattedString)

            } else if glucoseValueString.contains("Eventual BG"), glucoseValueString.contains("<") {
                // Handle Eventual BG XX < target
                let parts = glucoseValueString.components(separatedBy: "<")
                if parts.count == 2 {
                    let bgPart = parts[0].replacingOccurrences(of: "Eventual BG", with: "").trimmingCharacters(in: .whitespaces)
                    let targetValue = parts[1].trimmingCharacters(in: .whitespaces)
                    let formattedBGPart = convertToMmolL(bgPart)
                    let formattedTargetValue = convertToMmolL(targetValue)
                    let formattedString = "Eventual BG \(formattedBGPart)<\(formattedTargetValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }

            } else if glucoseValueString.contains("<") {
                // Handle minGuardBG (or minPredBG, etc.) x < y
                let parts = glucoseValueString.components(separatedBy: "<")
                if parts.count == 2 {
                    let firstValue = parts[0].trimmingCharacters(in: .whitespaces)
                    let secondValue = parts[1].trimmingCharacters(in: .whitespaces)
                    let formattedFirstValue = convertToMmolL(firstValue)
                    let formattedSecondValue = convertToMmolL(secondValue)
                    let formattedString = "minGuardBG \(formattedFirstValue)<\(formattedSecondValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }

            } else if glucoseValueString.contains(">=") {
                // Handle "Eventual BG X >= Y"
                let parts = glucoseValueString.components(separatedBy: " >= ")
                if parts.count == 2 {
                    let firstValue = parts[0].replacingOccurrences(of: "Eventual BG", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    let secondValue = parts[1].trimmingCharacters(in: .whitespaces)
                    let formattedFirstValue = convertToMmolL(firstValue)
                    let formattedSecondValue = convertToMmolL(secondValue)
                    let formattedString = "Eventual BG \(formattedFirstValue) >= \(formattedSecondValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }

            } else if glucoseValueString.contains(">"), glucoseValueString.contains("BG") {
                // Handle "maxDelta 37 > 20% of BG 95" style
                let localPattern = "(\\d+) > (\\d+)% of BG (\\d+)"
                let localRegex = try! NSRegularExpression(pattern: localPattern)
                let localMatches = localRegex.matches(
                    in: glucoseValueString,
                    range: NSRange(glucoseValueString.startIndex..., in: glucoseValueString)
                )
                if let localMatch = localMatches.first, localMatch.numberOfRanges == 4 {
                    let range1 = Range(localMatch.range(at: 1), in: glucoseValueString)!
                    let range2 = Range(localMatch.range(at: 2), in: glucoseValueString)!
                    let range3 = Range(localMatch.range(at: 3), in: glucoseValueString)!

                    let firstValue = convertToMmolL(String(glucoseValueString[range1]))
                    let thirdValue = convertToMmolL(String(glucoseValueString[range3]))

                    let oldSnippet =
                        "\(glucoseValueString[range1]) > \(glucoseValueString[range2])% of BG \(glucoseValueString[range3])"
                    let newSnippet = "\(firstValue) > \(glucoseValueString[range2])% of BG \(thirdValue)"

                    let replaced = glucoseValueString.replacingOccurrences(of: oldSnippet, with: newSnippet)
                    updatedReason.replaceSubrange(range, with: replaced)
                }

            } else {
                // Handle everything else, e.g., "minPredBG 39", "Dev: 5", etc.
                let parts = glucoseValueString.components(separatedBy: .whitespaces)
                if parts.count >= 2 {
                    var metric = parts[0]
                    let value = parts[1]

                    // Add ":" to the metric only if it doesn't already end with ":"
                    if !metric.hasSuffix(":") {
                        metric += ":"
                    }
                    let formattedValue = convertToMmolL(value)
                    let formattedString = "\(metric) \(formattedValue)"
                    updatedReason.replaceSubrange(range, with: formattedString)
                }
            }
        }

        return updatedReason
    }
}
