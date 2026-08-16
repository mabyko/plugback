#!/usr/bin/env swift

// assets/*.svg → 애셋 카탈로그 PNG. 저장소 루트에서 `swift Scripts/render-assets.swift`.
//
// qlmanage는 쓰지 않는다 — 썸네일 생성기라 투명 배경을 흰색으로 채운다. 메뉴바 글리프는
// 알파로 그려지므로 그러면 통짜 사각형이 되고, 앱 아이콘은 둥근 모서리가 흰색으로 남는다.
// NSImage는 macOS 13+에서 SVG를 그대로 읽는다(_NSSVGImageRep).

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func render(svg: String, to out: String, width: Int, height: Int) {
    let src = root.appendingPathComponent(svg)
    guard let image = NSImage(contentsOf: src) else {
        FileHandle.standardError.write(Data("cannot read \(svg)\n".utf8))
        exit(1)
    }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(1) }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    let dst = root.appendingPathComponent(out)
    try! png.write(to: dst)
    print("\(out)  \(width)x\(height)")
}

let icons = "App/Plugback/Assets.xcassets/AppIcon.appiconset"
for size in [16, 32, 64, 128, 256, 512, 1024] {
    render(svg: "assets/appicon.svg", to: "\(icons)/appicon_\(size).png", width: size, height: size)
}

// 글리프 viewBox는 24x18(4:3)이라 1x/2x가 정확히 두 배로 떨어진다.
let glyphs = "App/Plugback/Assets.xcassets/MenuBarGlyph.imageset"
for width in [20, 40] {
    render(svg: "assets/menubar-glyph.svg", to: "\(glyphs)/glyph_\(width).png",
           width: width, height: width * 3 / 4)
}
