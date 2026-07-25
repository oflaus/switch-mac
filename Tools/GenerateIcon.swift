#!/usr/bin/env swift
//
// Gera o ícone do app (AppIcon.iconset) sem depender do Xcode.
// Uso: swift Tools/GenerateIcon.swift <pasta-de-saida.iconset>
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("uso: GenerateIcon.swift <saida.iconset>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: CGFloat, in context: CGContext) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Proporções do ícone padrão do macOS: a arte ocupa 824 de 1024 pontos.
    let margin = size * 0.0977
    let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
    let cornerRadius = size * 0.1810

    // Fundo com degradê verde.
    context.saveGState()
    context.addPath(roundedRect(plate, radius: cornerRadius))
    context.clip()
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [0.16, 0.80, 0.47, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [0.03, 0.47, 0.36, 1.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: plate.minX, y: plate.maxY),
                               end: CGPoint(x: plate.maxX, y: plate.minY),
                               options: [])
    // Brilho suave no topo, sem borda dura.
    let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.16])!,
            CGColor(colorSpace: colorSpace, components: [1, 1, 1, 0.0])!
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(sheen,
                               start: CGPoint(x: plate.midX, y: plate.maxY),
                               end: CGPoint(x: plate.midX, y: plate.midY),
                               options: [])
    context.restoreGState()

    let stroke = max(size * 0.030, 1.0)
    context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.setLineWidth(stroke)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    // Celular, à esquerda.
    let phoneWidth = plate.width * 0.30
    let phoneHeight = plate.height * 0.56
    let phone = CGRect(x: plate.minX + plate.width * 0.11,
                       y: plate.midY - phoneHeight / 2,
                       width: phoneWidth,
                       height: phoneHeight)
    context.addPath(roundedRect(phone, radius: phoneWidth * 0.22))
    context.strokePath()

    // Alto-falante do celular.
    let speaker = CGRect(x: phone.midX - phoneWidth * 0.16,
                         y: phone.maxY - phoneHeight * 0.13,
                         width: phoneWidth * 0.32,
                         height: max(stroke * 0.8, 1))
    context.addPath(roundedRect(speaker, radius: speaker.height / 2))
    context.fillPath()

    // Setas de transferência, à direita.
    let arrowLeft = plate.minX + plate.width * 0.52
    let arrowRight = plate.maxX - plate.width * 0.11
    let head = plate.width * 0.10
    let gap = plate.height * 0.11

    func arrow(y: CGFloat, pointingRight: Bool) {
        let tipX = pointingRight ? arrowRight : arrowLeft
        let tailX = pointingRight ? arrowLeft : arrowRight
        context.move(to: CGPoint(x: tailX, y: y))
        context.addLine(to: CGPoint(x: tipX, y: y))
        context.strokePath()

        let direction: CGFloat = pointingRight ? -1 : 1
        context.move(to: CGPoint(x: tipX + head * direction, y: y + head * 0.62))
        context.addLine(to: CGPoint(x: tipX, y: y))
        context.addLine(to: CGPoint(x: tipX + head * direction, y: y - head * 0.62))
        context.strokePath()
    }

    arrow(y: plate.midY + gap, pointingRight: true)
    arrow(y: plate.midY - gap, pointingRight: false)
}

func writePNG(size: Int, to url: URL) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write(Data("não foi possível criar o contexto gráfico\n".utf8))
        exit(1)
    }
    drawIcon(size: CGFloat(size), in: context)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        FileHandle.standardError.write(Data("falha ao gerar \(url.lastPathComponent)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    writePNG(size: variant.pixels, to: outputDirectory.appendingPathComponent(variant.name))
}
print("ícone gerado em \(outputDirectory.path)")
