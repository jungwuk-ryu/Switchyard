import SwiftUI

struct BottlesView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bottles")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Table(store.bottles) {
                TableColumn("Name", value: \.name)
                TableColumn("Path") { bottle in
                    Text(bottle.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                TableColumn("Wine Build", value: \.wineBuildID)
                TableColumn("Patchset", value: \.patchsetID)
                TableColumn("Schema") { bottle in
                    Text("v\(bottle.schemaVersion)")
                }
            }
        }
        .padding()
        .navigationTitle("Bottles")
    }
}
