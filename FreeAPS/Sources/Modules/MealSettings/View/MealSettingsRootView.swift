import SwiftUI
import Swinject

extension MealSettings {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false
        @State private var displayPickerMaxCarbs: Bool = false
        @State private var displayPickerMaxFat: Bool = false
        @State private var displayPickerMaxProtein: Bool = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var conversionFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1

            return formatter
        }

        private var intFormater: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.allowsFloats = false
            return formatter
        }

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter
        }

        var body: some View {
            List {
                Section(
                    header: Text("Limits per Entry"),
                    content: {
                        VStack {
                            VStack {
                                HStack {
                                    Text("Max Carbs")

                                    Spacer()

                                    Group {
                                        Text(state.maxCarbs.description)
                                            .foregroundColor(!displayPickerMaxCarbs ? .primary : .accentColor)

                                        Text(" g").foregroundColor(.secondary)
                                    }
                                }
                                .onTapGesture {
                                    displayPickerMaxCarbs.toggle()
                                }
                            }.padding(.top)

                            if displayPickerMaxCarbs {
                                let setting = PickerSettingsProvider.shared.settings.maxCarbs
                                Picker(selection: $state.maxCarbs, label: Text("")) {
                                    ForEach(
                                        PickerSettingsProvider.shared.generatePickerValues(from: setting, units: state.units),
                                        id: \.self
                                    ) { value in
                                        Text("\(value.description)").tag(value)
                                    }
                                }
                                .pickerStyle(WheelPickerStyle())
                                .frame(maxWidth: .infinity)
                            }

                            if state.useFPUconversion {
                                VStack {
                                    HStack {
                                        Text("Max Fat")

                                        Spacer()

                                        Group {
                                            Text(state.maxFat.description)
                                                .foregroundColor(!displayPickerMaxFat ? .primary : .accentColor)

                                            Text(" g").foregroundColor(.secondary)
                                        }
                                    }
                                    .onTapGesture {
                                        displayPickerMaxFat.toggle()
                                    }
                                }
                                .padding(.top)

                                if displayPickerMaxFat {
                                    let setting = PickerSettingsProvider.shared.settings.maxFat
                                    Picker(selection: $state.maxFat, label: Text("")) {
                                        ForEach(
                                            PickerSettingsProvider.shared.generatePickerValues(from: setting, units: state.units),
                                            id: \.self
                                        ) { value in
                                            Text("\(value.description)").tag(value)
                                        }
                                    }
                                    .pickerStyle(WheelPickerStyle())
                                    .frame(maxWidth: .infinity)
                                }

                                VStack {
                                    HStack {
                                        Text("Max Protein")

                                        Spacer()

                                        Group {
                                            Text(state.maxProtein.description)
                                                .foregroundColor(!displayPickerMaxProtein ? .primary : .accentColor)

                                            Text(" g").foregroundColor(.secondary)
                                        }
                                    }
                                    .onTapGesture {
                                        displayPickerMaxProtein.toggle()
                                    }
                                }
                                .padding(.top)

                                if displayPickerMaxProtein {
                                    let setting = PickerSettingsProvider.shared.settings.maxProtein
                                    Picker(selection: $state.maxProtein, label: Text("")) {
                                        ForEach(
                                            PickerSettingsProvider.shared.generatePickerValues(from: setting, units: state.units),
                                            id: \.self
                                        ) { value in
                                            Text("\(value.description)").tag(value)
                                        }
                                    }
                                    .pickerStyle(WheelPickerStyle())
                                    .frame(maxWidth: .infinity)
                                }
                            }

                            HStack(alignment: .center) {
                                Text(
                                    "Set limits for each type of macro per meal entry."
                                )
                                .lineLimit(nil)
                                .font(.footnote)
                                .foregroundColor(.secondary)

                                Spacer()
                                Button(
                                    action: {
                                        hintLabel = "Limits per Entry"
                                        selectedVerboseHint =
                                            AnyView(
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text("Max Carbs:").bold()
                                                    Text("Enter the largest carbohydrate value allowed per meal entry")
                                                    Text("Max Fat:").bold()
                                                    Text("Enter the largest fat value allowed per meal entry")
                                                    Text("Max Protein:").bold()
                                                    Text("Enter the largest protein value allowed per meal entry")
                                                }
                                            )
                                        shouldDisplayHint.toggle()
                                    },
                                    label: {
                                        HStack {
                                            Image(systemName: "questionmark.circle")
                                        }
                                    }
                                ).buttonStyle(BorderlessButtonStyle())
                            }.padding(.top)
                        }.padding(.bottom)
                    }
                ).listRowBackground(Color.chart)

                SettingInputSection(
                    decimalValue: $state.maxMealAbsorptionTime,
                    booleanValue: $booleanPlaceholder,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = "Maximum Meal Absorption Time"
                        }
                    ),
                    units: state.units,
                    type: .decimal("maxMealAbsorptionTime"),
                    label: "Max Meal Absorption Time",
                    miniHint: "The max meal absorption time limits the duration the algorithm will track carb entries in estimating Carbs on Board (COB)",
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: 6 hours").bold()
                        Text(
                            "Meals that are high in fat and protein can slow digestion. This can result in the Carbohydrate on Board (COB) determination excluding carbs that are still being absorbed beyond the default time frame of 6 hours."
                        )
                        Text(
                            "Increasing this setting will extend the time frame that carbs entered are available for determining COB."
                        )
                    }
                )

                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.useFPUconversion,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = "Enable Fat and Protein Entries"
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: "Enable Fat and Protein Entries",
                    miniHint: "Add fat and protein macros to meal entries.",
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        VStack(spacing: 10) {
                            Text(
                                "Enabling this setting allows you to log fat and protein, which are then converted into future carb equivalents using the Warsaw Method."
                            )
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Warsaw Method:").bold()
                                Text(
                                    "The Warsaw Method helps account for the delayed glucose spikes caused by fat and protein in meals. It uses Fat-Protein Units (FPU) to calculate the carb effect from fat and protein. The system spreads insulin delivery over several hours to mimic natural insulin release, helping to manage post-meal glucose spikes."
                                )
                            }
                            VStack(alignment: .center, spacing: 5) {
                                Text("Fat Conversion").bold()
                                Text("𝑭 = fat(g) × 90%")
                            }
                            VStack(alignment: .center, spacing: 5) {
                                Text("Protein Conversion").bold()
                                Text("𝑷 = protein(g) × 40%")
                            }
                            VStack(alignment: .center, spacing: 5) {
                                Text("FPU Conversion").bold()
                                Text("𝑭 + 𝑷 = g CHO")
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(
                                    "You can personalize the conversion calculation by adjusting the following settings that will appear when this option is enabled:"
                                )
                                Text("• Fat and Protein Delay")
                                Text("• Maximum Duration")
                                Text("• Spread Interval")
                                Text("• Fat and Protein Percentage")
                            }
                        }
                    },
                    headerText: "Fat and Protein"
                )
                if state.useFPUconversion {
                    SettingInputSection(
                        decimalValue: $state.delay,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = "Fat and Protein Delay"
                            }
                        ),
                        units: state.units,
                        type: .decimal("delay"),
                        label: "Fat and Protein Delay",
                        miniHint: "Delay between fat & protein entry and first FPU entry.",
                        verboseHint:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 60 min").bold()
                            Text(
                                "The Fat and Protein Delay setting defines the time between when you log fat and protein and when the system starts delivering insulin for the Fat-Protein Unit Carb Equivalents (FPUs)."
                            )
                            Text(
                                "This delay accounts for the slower absorption of fat and protein, as calculated by the Warsaw Method, ensuring insulin delivery is properly timed to manage glucose spikes caused by high-fat, high-protein meals."
                            )
                        }
                    )

                    SettingInputSection(
                        decimalValue: $state.timeCap,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = "Maximum Duration"
                            }
                        ),
                        units: state.units,
                        type: .decimal("timeCap"),
                        label: "Maximum Duration",
                        miniHint: "Set the maximum timeframe to extend FPUs.",
                        verboseHint:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 8 hours").bold()
                            Text(
                                "This sets the maximum length of time that Fat and Protein Carb Equivalents (FPUs) will be extended over from a single Fat and/or Protein bolus calcultor entry."
                            )
                            Text(
                                "It is one factor used in combination with the Fat and Protein Delay, Spread Interval, and Fat and Protein Factor to create the FPU entries."
                            )
                            Text("Increasing this setting may result in more FPU entries with smaller carb values.")
                            Text("Decreasing this setting may result in fewer FPU entries with larger carb values.")
                        }
                    )

                    SettingInputSection(
                        decimalValue: $state.minuteInterval,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = "Spread Interval"
                            }
                        ),
                        units: state.units,
                        type: .decimal("minuteInterval"),
                        label: "Spread Interval",
                        miniHint: "Time interval between FPUs.",
                        verboseHint:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 30 minutes").bold()
                            Text(
                                "This determines how many minutes will be between individual Fat-Protein Unit Carb Equivalent (FPU) entries from a single Fat and/or Protein bolus calculator entry."
                            )
                            Text("The shorter the interval, the smoother the correlating dosing result.")
                            Text("Increasing this setting may result in fewer FPU entries with larger carb values.")
                            Text("Decreasing this setting may result in more FPU entries with smaller carb values.")
                        }
                    )

                    SettingInputSection(
                        decimalValue: $state.individualAdjustmentFactor,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = "Fat and Protein Percentage"
                            }
                        ),
                        units: state.units,
                        type: .decimal("individualAdjustmentFactor"),
                        label: "Fat and Protein Percentage",
                        miniHint: "Adjust the Warsaw Method FPU Conversion rate.",
                        verboseHint: VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 50%").bold()
                            VStack(spacing: 10) {
                                Text("This setting changes how much effect the fat and protein entry has on FPUs.")
                                VStack(alignment: .center, spacing: 5) {
                                    Text("50% is half effect:").bold()
                                    Text("(Fat × 45%) + (Protein × 20%)")
                                    Text("100% is full effect:").bold()
                                    Text("(Fat × 90%) + (Protein × 40%)")
                                    Text("110% makes fat-to-carbs ratio essentially equal:").bold()
                                    Text("(Fat × 99%) + (Protein x 44%)")
                                }
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                Text(
                                    "Tip: You may find that your normal carb ratio needs to increase to a larger number when you begin adding fat and protein entries. For this reason, it is best to start with a factor of about 50%."
                                )
                            }
                        }
                    )
                }
            }
            .listSectionSpacing(sectionSpacing)
            .sheet(isPresented: $shouldDisplayHint) {
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: $shouldDisplayHint,
                    hintLabel: hintLabel ?? "",
                    hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                    sheetTitle: "Help"
                )
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Meal Settings")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}
