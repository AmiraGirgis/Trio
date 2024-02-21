import SwiftUI

struct CustomProgressView: View {
    @State var animate = false

    let text: String

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            Text(text)
                .font(.system(.body, design: .rounded))
                .bold()
                .offset(x: 0, y: -25)

            RoundedRectangle(cornerRadius: 3)
                .stroke(Color(.systemGray5), lineWidth: 3)
                .frame(width: 250, height: 3)

            RoundedRectangle(cornerRadius: 3)
                .stroke(LinearGradient(colors: [
                    Color(red: 0.7215686275, green: 0.3411764706, blue: 1),
                    Color(red: 0.6235294118, green: 0.4235294118, blue: 0.9803921569),
                    Color(red: 0.4862745098, green: 0.5450980392, blue: 0.9529411765),
                    Color(red: 0.3411764706, green: 0.6666666667, blue: 0.9254901961),
                    Color(red: 0.262745098, green: 0.7333333333, blue: 0.9137254902)
                ], startPoint: .leading, endPoint: .trailing), lineWidth: 3)
                .frame(width: 250, height: 3)
                .mask(
                    RoundedRectangle(cornerRadius: 3)
                        .frame(width: 80, height: 3)
                        .offset(x: self.animate ? 180 : -180, y: 0)
                        .animation(
                            Animation.linear(duration: 2)
                                .repeatForever(autoreverses: false), value: UUID()
                        )
                )
        }
        .onAppear {
            self.animate.toggle()
        }
    }
}
