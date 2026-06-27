import SwiftUI
import AppKit

// SwiftUI root for the Acknowledgements / Open Source Licenses panel.
//
// Master/detail: the left column lists every component grouped by how it
// relates to MacXServer (the app itself, bundled software, transcribed source,
// references studied). The right pane shows the selected component's "how we
// used it" note, a link to the upstream project, and the full verbatim license
// text.
//
// We use a plain HSplitView rather than NavigationSplitView: the latter pulls
// in an automatic toolbar / sidebar-collapse behavior that fights a bare NSPanel
// (the sidebar collapses to nothing and content leaks under the title bar).
// HSplitView is the boring, predictable AppKit-backed split.

struct AcknowledgementsView: View {

    @State private var selection: Acknowledgement.ID? = Acknowledgement.all.first?.id

    private var selected: Acknowledgement? {
        Acknowledgement.all.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(Acknowledgement.Kind.allCases, id: \.self) { kind in
                let entries = Acknowledgement.entries(in: kind)
                if !entries.isEmpty {
                    Section(kind.sectionTitle) {
                        ForEach(entries) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                HStack(spacing: 6) {
                                    if let version = item.version {
                                        Text(version)
                                    }
                                    Text(item.license)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .tag(item.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let selected {
            AcknowledgementDetail(item: selected)
        } else {
            Text("Select a component.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AcknowledgementDetail: View {

    let item: Acknowledgement

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            usageBox
            licenseBox
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name)
                    .font(.title2)
                if let version = item.version {
                    Text(version)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Label(item.kind.sectionTitle, systemImage: kindSymbol)
                Text(item.license)
                if let url = item.url {
                    Link(destination: url) {
                        Label(shortLink(url), systemImage: "arrow.up.right.square")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var usageBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How MacXServer uses this")
                .font(.headline)
            Text(item.usage)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var licenseBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.licenseText.isEmpty ? "License" : "License \u{2014} \(item.license)")
                .font(.headline)
            if item.licenseText.isEmpty {
                Text("Reference material \u{2014} no source code from this is incorporated into MacXServer, so there is no license text to reproduce. See the linked project for its own terms.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    Text(item.licenseText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var kindSymbol: String {
        switch item.kind {
        case .app:         return "app.badge"
        case .bundled:     return "shippingbox"
        case .transcribed: return "doc.on.doc"
        case .referenced:  return "book"
        }
    }

    private func shortLink(_ url: URL) -> String {
        url.host ?? url.absoluteString
    }
}
