// Run: scripts/tests/render_design_shots.sh
// Renders the design kit in DesignSystem.swift to PNG files without launching Teachy.
// Nothing is put on screen. Output: $TMPDIR/teachy-design-shots/
import AppKit
import SwiftUI

@MainActor
func runShots() {
    let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("teachy-design-shots", isDirectory: true)
    try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var failureCount = 0

    func render<V: View>(_ view: V, width: CGFloat, name: String) {
        let hosting = NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .dark))
        let size = NSSize(width: width, height: hosting.fittingSize.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { failureCount += 1; print("FAIL no bitmap for \(name)"); return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { failureCount += 1; print("FAIL no PNG for \(name)"); return }
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try? data.write(to: url)
        print("wrote \(url.path) (\(Int(size.width))x\(Int(size.height)))")
    }

    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    func boardSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TeachySectionTitle(title: title)
            content()
        }
    }

    func swatch(_ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
                .frame(width: 84, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.hairline, lineWidth: 1))
            Text(name).font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
        }
    }

    let board = VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("Hold").font(DS.Fonts.display)
                KeyboardKeyLabel(text: "control", isProminent: true)
                KeyboardKeyLabel(text: "option", isProminent: true)
                Text("and ask.").font(DS.Fonts.display)
            }
            .foregroundColor(DS.Colors.textPrimary)
            Text("Teachy looks like part of macOS: SF Pro, system glass, grouped lists, one tint.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        boardSection("Type") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Display. Finally do the thing.").font(DS.Fonts.display).foregroundColor(DS.Colors.textPrimary)
                Text("Title. Routines").font(DS.Fonts.title).foregroundColor(DS.Colors.textPrimary)
                Text("Item title. Umbrella Check").font(DS.Fonts.itemTitle).foregroundColor(DS.Colors.textPrimary)
                Text("Voice. Take an umbrella to your 5 p.m. game: thunderstorms are likely from 4 to 7.").font(DS.Fonts.voice).lineSpacing(3).foregroundColor(DS.Colors.textPrimary)
                Text("Body. Captions while Teachy talks").font(DS.Fonts.body).foregroundColor(DS.Colors.textPrimary)
                Text("Caption. Shows the words at the bottom of your screen as they are spoken.").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                Text("Data. Weekdays at 9:00 · Next Mon · 3 steps · 7s").font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
                Text("mono  rm -rf ~/Downloads/old-builds").font(DS.Fonts.mono(11)).foregroundColor(DS.Colors.textSecondary)
            }
        }

        boardSection("Colour") {
            HStack(spacing: 10) {
                swatch("notch", DS.Colors.notchBlack)
                swatch("background", DS.Colors.background)
                swatch("surface1", DS.Colors.surface1)
                swatch("surface2", DS.Colors.surface2)
                swatch("surface3", DS.Colors.surface3)
                swatch("surface4", DS.Colors.surface4)
            }
            HStack(spacing: 10) {
                swatch("primary", DS.Colors.textPrimary)
                swatch("secondary", DS.Colors.textSecondary)
                swatch("tertiary", DS.Colors.textTertiary)
                swatch("needs you", DS.Colors.warning)
                swatch("failed", DS.Colors.destructive)
                swatch("done", DS.Colors.success)
            }
            HStack(spacing: 10) {
                swatch("tint: blue", DS.Colors.pointerColor(named: "blue"))
                swatch("tint: red", DS.Colors.pointerColor(named: "red"))
                swatch("tint: yellow", DS.Colors.pointerColor(named: "yellow"))
                swatch("tint: green", DS.Colors.pointerColor(named: "green"))
            }
        }

        boardSection("Buttons") {
            HStack(spacing: 10) {
                Button("Go ahead") {}.teachyButton(.primary)
                Button("Always allow") {}.teachyButton(.secondary)
                Button("Not now") {}.teachyButton(.quiet)
                Button("Delete") {}.teachyButton(.danger)
                Button("Disabled") {}.teachyButton(.primary).disabled(true)
            }
            HStack(spacing: 8) {
                Button("New agent") {}.teachyButton(.primary, size: .compact)
                Button("Change") {}.teachyButton(.secondary, size: .compact)
                Button("Reset") {}.teachyButton(.quiet, size: .compact)
                Button("Stop") {}.teachyButton(.danger, size: .compact)
                Button { } label: { Image(systemName: "xmark") }.teachyIconButton()
                Button { } label: { Image(systemName: "chevron.left") }.teachyIconButton()
                Button("Rename") {}.teachyLinkButton()
                Button("Open folder") {}.teachyLinkButton()
                Button("Delete") {}.teachyLinkButton(color: DS.Colors.destructiveText)
            }
        }

        boardSection("Keys, switches, options, states") {
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    KeyboardKeyLabel(text: "control")
                    KeyboardKeyLabel(text: "option")
                    KeyboardKeyLabel(text: "fn")
                    KeyboardKeyLabel(text: "esc")
                }
                TeachySwitch(isOn: true)
                TeachySwitch(isOn: false)
                HStack(spacing: 10) {
                    ForEach(Array([TeachyStatusKind.live, .done, .needsYou, .failed, .waiting, .stopped].enumerated()), id: \.offset) { _, statusKind in
                        TeachyStatusMark(kind: statusKind)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(["Puck", "Aoede", "Kore"], id: \.self) { voiceName in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(voiceName).font(DS.Fonts.bodyEmphasized).foregroundColor(DS.Colors.textPrimary)
                        Text("Upbeat, friendly").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: 130, alignment: .leading)
                    .teachyOption(isSelected: voiceName == "Puck")
                }
            }
        }

        boardSection("A grouped list") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(["Builder", "Research buddy", "Inbox helper"].enumerated()), id: \.offset) { rowIndex, agentName in
                    if rowIndex > 0 { TeachyRule() }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agentName).font(DS.Fonts.itemTitle).foregroundColor(DS.Colors.textPrimary)
                            Text("Builds small apps, scripts and sites on this Mac.").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                        }
                        Spacer()
                        Button("Rename") {}.teachyLinkButton()
                        Button("Delete") {}.teachyLinkButton(color: DS.Colors.destructiveText)
                    }
                    .padding(.vertical, 10)
                }
            }
            .teachyGroup()
        }

        boardSection("Glass (a frosted stand-in off screen)") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TeachyStatusMark(kind: .live)
                        Text("Laptop Prices").font(DS.Fonts.itemTitle).foregroundColor(DS.Colors.textPrimary)
                        Spacer()
                        Button("Stop") {}.teachyButton(.danger, size: .compact)
                    }
                    Text("Searching the web").font(DS.Fonts.data).foregroundColor(DS.Colors.textTertiary)
                }
                .padding(14)
                .frame(width: 280)
                .teachyTile()
                .padding(14)
                .background(Color(white: 0.42))

                HStack(spacing: 8) {
                    TeachyStatusMark(kind: .live, sideLength: 12)
                    Text("Listening").font(DS.Fonts.controlCompact).foregroundColor(DS.Colors.textPrimary)
                }
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .teachyTile(cornerRadius: DS.CornerRadius.pill)
                .padding(14)
                .background(Color(white: 0.42))

                VStack(alignment: .leading, spacing: 6) {
                    Text("A well").font(DS.Fonts.bodyEmphasized).foregroundColor(DS.Colors.textPrimary)
                    Text("rm -rf ~/Downloads/old-builds").font(DS.Fonts.mono(11)).foregroundColor(DS.Colors.textSecondary)
                }
                .padding(12)
                .frame(width: 210, alignment: .leading)
                .teachyWell()
            }
        }
    }
    .padding(28)
    .background(DS.Colors.notchBlack)

    render(board, width: 720, name: "01-design-kit")

    if failureCount > 0 {
        print("\(failureCount) FAILED")
        exit(1)
    }
    print("ALL RENDERED")
}

MainActor.assumeIsolated { runShots() }
