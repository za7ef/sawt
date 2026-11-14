import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: ChatStore
    @EnvironmentObject var models: ModelManager
    @State private var orphans: [Storage.ModelFolder] = []
    @State private var crashNotice = Log.shared.previousRunCrashed
    @State private var shareURL: URL?
    @State private var drawerOpen = false
    @State private var drag: CGFloat = 0
    private let drawerWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let open = drawerOpen ? drawerWidth : 0
            let offset = max(0, min(drawerWidth, open + drag))
            ZStack(alignment: .leading) {
                DrawerView(close: { setDrawer(false) })
                    .frame(width: drawerWidth)
                    .offset(x: offset - drawerWidth)
                    .opacity(Double(offset / drawerWidth))

                ChatView(openDrawer: { setDrawer(true) })
                    .frame(width: geo.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: offset > 0 ? 28 : 0, style: .continuous))
                    .scaleEffect(1 - 0.06 * (offset / drawerWidth))
                    .offset(x: offset)
                    .overlay {
                        if offset > 0 {
                            Color.black.opacity(0.25 * Double(offset / drawerWidth))
                                .offset(x: offset)
                                .onTapGesture { setDrawer(false) }
                        }
                    }
            }
            .background(Theme.bg.ignoresSafeArea())
            .alert("التطبيق انقفل المرة اللي فاتت", isPresented: $crashNotice) {
                Button("صدّر السجل") { shareURL = Log.shared.export() }
                Button("خلاص", role: .cancel) {}
            } message: {
                Text("كان وقتها في: \(Log.shared.previousStage). السجل محفوظ، صدّره وأرسله عشان نعرف السبب.")
            }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
                if let u = shareURL { ActivityView(items: [u]) }
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { v in
                        // في الواجهة العربية الاتجاه مقلوب تلقائيًا
                        if drawerOpen || v.startLocation.x < 40 || abs(v.translation.width) > abs(v.translation.height) * 2 {
                            drag = v.translation.width
                        }
                    }
                    .onEnded { v in
                        let target = (drawerOpen ? drawerWidth : 0) + v.predictedEndTranslation.width
                        setDrawer(target > drawerWidth / 2)
                        drag = 0
                    }
            )
        }
    }

    private var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.bytes } }

    private func setDrawer(_ open: Bool) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            drawerOpen = open
            drag = 0
        }
    }
}

struct DrawerView: View {
    @EnvironmentObject var store: ChatStore
    var close: () -> Void
    @State private var search = ""
    @State private var showSettings = false
    @State private var showModels = false

    var filtered: [Conversation] {
        search.isEmpty ? store.conversations
            : store.conversations.filter { c in
                c.title.localizedCaseInsensitiveContains(search)
                    || c.messages.contains { $0.text.localizedCaseInsensitiveContains(search) }
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("بحث", text: $search)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .glassEffect(.regular, in: .capsule)

            Button {
                store.newConversation(); close()
            } label: {
                Label("محادثة جديدة", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)

            Text("المحادثات").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { c in
                        Button {
                            store.select(c.id); close()
                        } label: {
                            Text(c.title)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10).padding(.horizontal, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(c.id == store.currentID ? Color.white.opacity(0.09) : .clear))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { store.delete(c.id) } label: {
                                Label("حذف", systemImage: "trash")
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Text("ما فيه محادثات للحين").foregroundStyle(.secondary).padding(12)
                    }
                }
            }
            .scrollIndicators(.hidden)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    Button { showModels = true } label: {
                        Label("النماذج", systemImage: "cpu").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button { showSettings = true } label: {
                        Label("الإعدادات", systemImage: "gearshape").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showModels) { ModelsView() }
    }
}
