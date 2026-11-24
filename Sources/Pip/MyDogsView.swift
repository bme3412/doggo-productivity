import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MyDogsView: View {
    @ObservedObject var store: DogAppearance
    @State private var selection: UUID?
    @State private var picking = false
    @State private var importing = false
    @State private var pending: PhotoBatch?
    @State private var importError: String?

    private struct PhotoBatch: Identifiable {
        let id = UUID()
        let dogs: [ImportedDog]
    }

    private var selectedDog: DogProfile? {
        store.profiles.first(where: { $0.id == selection }) ?? store.profiles.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("On desktop", selection: desktop) {
                    Text("Classic Doggo").tag([DesktopDog.classic.id])
                    Text("Black dog").tag([DesktopDog.black.id])
                    Text("Classic Doggo + black dog").tag(DesktopDog.builtIns.map(\.id))
                    if !store.profiles.isEmpty {
                        Divider()
                        ForEach(store.profiles) { Text($0.name).tag([$0.id]) }
                        if store.profiles.count == 2 { Text("Both photo dogs").tag(store.profiles.map(\.id)) }
                    }
                }
                .fixedSize()
                if store.visibleDogs.count == 2 {
                    Picker("Guide", selection: Binding(get: { store.guide.id }, set: store.chooseGuide)) {
                        ForEach(store.visibleDogs) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    .help("The guide gives reminders and offers high fives.")
                }
                Spacer()
                if importing { ProgressView().controlSize(.small).accessibilityLabel("Reading photos") }
                Button { picking = true } label: {
                    Label("Add photos…", systemImage: "photo.badge.plus")
                }
                .disabled(store.availableSlots == 0 || importing)
                .help(store.availableSlots == 0 ? "My Dogs has room for two dogs." : "Choose dog photos")
            }
            .padding(16)
            Divider()

            if let dog = selectedDog {
                if store.profiles.count == 2 {
                    Picker("Edit dog", selection: Binding(get: { dog.id }, set: { selection = $0 })) {
                        ForEach(store.profiles) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .padding(.top, 16)
                }
                DogLookEditor(profile: dog, store: store).id(dog.id)
            } else {
                ContentUnavailableView("Make Doggo yours", systemImage: "pawprint",
                                       description: Text("Choose a photo of one or two dogs to make illustrated desktop companions."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = importError ?? store.error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image],
                      allowsMultipleSelection: store.availableSlots > 1, onCompletion: readPhotos)
        .sheet(item: $pending) { batch in
            DogImportReview(dogs: batch.dogs, capacity: store.availableSlots) { dogs in
                guard store.add(dogs) else {
                    return store.error ?? "My Dogs has room for two dogs."
                }
                selection = dogs.first?.id
                pending = nil
                return nil
            }
        }
    }

    private var desktop: Binding<[UUID]> {
        Binding(get: { store.visibleDogs.map(\.id) }, set: { store.show($0) })
    }

    private func readPhotos(_ result: Result<[URL], Error>) {
        importError = nil
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            guard urls.count <= store.availableSlots else {
                importError = "Choose up to \(store.availableSlots) photos."
                return
            }
            importing = true
            Task {
                defer { importing = false }
                do {
                    let dogs = try await Task.detached(priority: .userInitiated) {
                        try DogPhotoImport.drafts(from: urls)
                    }.value
                    pending = PhotoBatch(dogs: dogs)
                } catch {
                    importError = error.localizedDescription
                }
            }
        } catch {
            let issue = error as NSError
            if issue.domain != NSCocoaErrorDomain || issue.code != NSUserCancelledError {
                importError = issue.localizedDescription
            }
        }
    }
}

private struct DogLookEditor: View {
    let profile: DogProfile
    @ObservedObject var store: DogAppearance
    @State private var draft: DogProfile
    @State private var removing = false

    init(profile: DogProfile, store: DogAppearance) {
        self.profile = profile
        self.store = store
        _draft = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 12) {
                        DogIllustration(look: draft.look, scale: 1.35)
                        DogReferencePhoto(data: profile.referencePhoto, height: 135)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Name", text: $draft.name)
                        Divider()
                        HStack {
                            colorPicker("Coat", color: $draft.look.coat)
                            Spacer()
                            colorPicker("Muzzle", color: $draft.look.muzzle)
                        }
                        HStack {
                            colorPicker("Ear color", color: $draft.look.earColor)
                            Spacer()
                            colorPicker("Marking color", color: $draft.look.markingsColor)
                                .disabled(draft.look.markings == .solid)
                        }
                        Picker("Ears", selection: $draft.look.ears) {
                            ForEach(DogLook.Ears.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Picker("Tail", selection: $draft.look.tail) {
                            ForEach(DogLook.Tail.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Picker("Coat pattern", selection: $draft.look.markings) {
                            ForEach(DogLook.Markings.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        HStack {
                            Toggle("Long muzzle", isOn: $draft.look.longMuzzle)
                            Spacer()
                            Toggle("Light chest patch", isOn: $draft.look.chestPatch)
                        }
                        HStack {
                            accessory("Collar", color: $draft.look.collar, initial: 0x519DA1)
                            Spacer()
                            accessory("Harness", color: $draft.look.harness, initial: 0xAB353D)
                        }
                    }
                    .frame(width: 292)
                }
                .padding(22)
            }
            Divider()
            HStack {
                Button("Remove dog…", role: .destructive) { removing = true }
                Spacer()
                Button("Save changes") {
                    if store.save(draft) {
                        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == profile || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .confirmationDialog("Remove \(profile.name) from My Dogs?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove dog", role: .destructive) { store.remove(profile.id) }
        }
    }

    private func colorPicker(_ title: String, color: Binding<UInt32>) -> some View {
        ColorPicker(title, selection: Binding(get: { Color(hex: color.wrappedValue) }, set: { new in
            guard let rgb = NSColor(new).usingColorSpace(.sRGB) else { return }
            let red = UInt32((255 * min(1, max(0, rgb.redComponent))).rounded())
            let green = UInt32((255 * min(1, max(0, rgb.greenComponent))).rounded())
            let blue = UInt32((255 * min(1, max(0, rgb.blueComponent))).rounded())
            color.wrappedValue = (red << 16) | (green << 8) | blue
        }), supportsOpacity: false)
        .fixedSize()
    }

    private func accessory(_ title: String, color: Binding<UInt32?>, initial: UInt32) -> some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: Binding(get: { color.wrappedValue != nil }, set: {
                color.wrappedValue = $0 ? initial : nil
            }))
            if color.wrappedValue != nil {
                colorPicker("\(title) color", color: Binding(get: { color.wrappedValue ?? initial },
                                                             set: { color.wrappedValue = $0 }))
                    .labelsHidden()
            }
        }
        .fixedSize()
    }
}

private struct DogIllustration: View {
    var look: DogLook
    var scale: CGFloat

    var body: some View {
        DogView(mood: .awake, moodChangedAt: .distantPast, bandana: Theme.sage, artwork: .photo(look), scale: scale)
            .offset(x: -24 * scale)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Animated illustration")
    }
}

private struct DogReferencePhoto: View {
    var data: Data
    var height: CGFloat

    var body: some View {
        if let photo = NSImage(data: data) {
            Image(nsImage: photo)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Reference photo")
        }
    }
}

private struct DogImportReview: View {
    let capacity: Int
    let onAdd: ([DogProfile]) -> String?
    @State private var dogs: [ImportedDog]
    @State private var selected: Set<UUID>
    @State private var cropping: ImportedDog?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(dogs: [ImportedDog], capacity: Int, onAdd: @escaping ([DogProfile]) -> String?) {
        self.capacity = capacity
        self.onAdd = onAdd
        _dogs = State(initialValue: dogs)
        _selected = State(initialValue: Set(dogs.prefix(capacity).map(\.id)))
    }

    var body: some View {
        Group {
            if let cropping {
                DogPhotoCrop(dog: cropping, cancel: { self.cropping = nil }) { edited in
                    if let index = dogs.firstIndex(where: { $0.id == edited.id }) {
                        dogs[index] = edited
                    } else {
                        dogs.append(edited)
                        select(edited.id, included: true)
                    }
                    self.cropping = nil
                }
                .id(cropping.id)
            } else {
                review
            }
        }
        .frame(width: dogs.count == 2 && cropping == nil ? 690 : 490)
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review your dogs").font(.title2.weight(.semibold))
            if dogs.count > capacity {
                Text("There’s room for one more dog. Choose which one to keep.").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                ForEach($dogs) { $dog in
                    VStack(spacing: 8) {
                        DogIllustration(look: dog.profile.look, scale: 0.95)
                        DogReferencePhoto(data: dog.profile.referencePhoto, height: 112)
                        TextField("Dog name", text: $dog.profile.name)
                        HStack {
                            if dogs.count == 2 {
                                Toggle("Include", isOn: Binding(get: { selected.contains(dog.id) },
                                                                set: { select(dog.id, included: $0) }))
                            }
                            Spacer()
                            Button("Crop photo…") { cropping = dog }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if capacity > dogs.count, let dog = dogs.first {
                Button("Crop a second dog from this photo…") {
                    var second = dog
                    second.profile.id = UUID()
                    second.profile.name = "Dog 2"
                    cropping = second
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to My Dogs") { error = onAdd(chosenDogs) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenDogs.isEmpty || chosenDogs.contains { $0.name.isEmpty })
            }
        }
        .padding(20)
    }

    private var chosenDogs: [DogProfile] {
        dogs.filter { selected.contains($0.id) }.map {
            var profile = $0.profile
            profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return profile
        }
    }

    private func select(_ id: UUID, included: Bool) {
        if included {
            if capacity == 1 { selected = [] }
            selected.insert(id)
        } else {
            selected.remove(id)
        }
    }
}

private struct DogPhotoCrop: View {
    let dog: ImportedDog
    let cancel: () -> Void
    let apply: (ImportedDog) -> Void
    @State private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var processing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop \(dog.profile.name)’s photo").font(.title2.weight(.semibold))
            Text("Drag a box around the dog you want to use.").foregroundStyle(.secondary)
            if let photo = NSImage(data: dog.sourcePhoto) {
                GeometryReader { proxy in
                    let scale = min(proxy.size.width / photo.size.width, proxy.size.height / photo.size.height)
                    let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                    ZStack(alignment: .topLeading) {
                        Image(nsImage: photo).resizable().frame(width: size.width, height: size.height)
                        Rectangle()
                            .fill(.white.opacity(0.12))
                            .border(.white, width: 2)
                            .frame(width: region.width * size.width, height: region.height * size.height)
                            .offset(x: region.minX * size.width, y: region.minY * size.height)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3).onChanged { drag in
                        let a = normalized(drag.startLocation, in: size)
                        let b = normalized(drag.location, in: size)
                        region = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                        width: abs(a.x - b.x), height: abs(a.y - b.y))
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(processing)
                    .accessibilityLabel("Crop area")
                }
                .frame(height: 328)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                if processing { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Use crop", action: crop)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(processing || region.width < 0.05 || region.height < 0.05)
            }
            .disabled(processing)
        }
        .padding(20)
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / size.width)), y: min(1, max(0, point.y / size.height)))
    }

    private func crop() {
        processing = true
        error = nil
        let source = dog
        let bounds = region
        Task {
            defer { processing = false }
            do {
                let cropped = try await Task.detached(priority: .userInitiated) {
                    try DogPhotoImport.crop(source, to: bounds)
                }.value
                apply(cropped)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
