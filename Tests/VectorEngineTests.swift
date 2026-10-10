import XCTest
import Foundation
import CoreGraphics
@testable import VectorEngine

final class VectorEngineTests: XCTestCase {
    func testLargePresentationRetainsAll1041TopicsAndEditableIcons() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let icons = try AIParser().analyze(url: fixture).pictograms
        let jobs = (1...1041).reversed().map { SVGExportJob(name: String(format: "主题%04d", $0), icons: icons) }
        let file = folder.appendingPathComponent("large.pptx")
        XCTAssertEqual(try PresentationExporter.write(jobs, color: .yellow, to: file), 1041)
        let unpack = folder.appendingPathComponent("unpack")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", file.path, unpack.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let slides = try FileManager.default.contentsOfDirectory(at: unpack.appendingPathComponent("ppt/slides"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "xml" }
        XCTAssertEqual(slides.count, 1041)
        for index in [1, 521, 1041] {
            let xml = try String(contentsOf: unpack.appendingPathComponent("ppt/slides/slide\(index).xml"))
            XCTAssertTrue(xml.contains(String(format: "主题%04d", index)))
            XCTAssertEqual(xml.components(separatedBy: "<p:grpSp>").count-1, icons.count)
            XCTAssertFalse(xml.contains("<p:pic>"))
        }
    }
    func testPresentationUsesNativeGroupsAndOneSortedThemePerSlide() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let icons = Array(try AIParser().analyze(url: fixture).pictograms.prefix(4))
        let jobs = [SVGExportJob(name: "主题02 & 足球", icons: icons), SVGExportJob(name: "主题01", icons: Array(icons.prefix(1)))]
        let file = folder.appendingPathComponent("test.pptx")
        var updates: [SVGExportProgress] = []
        XCTAssertEqual(try PresentationExporter.write(jobs, color: .yellow, to: file) { updates.append($0) }, 2)
        let unpack = folder.appendingPathComponent("unpack")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", file.path, unpack.path]; try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpack.appendingPathComponent("_rels/.rels").path))
        let first = try String(contentsOf: unpack.appendingPathComponent("ppt/slides/slide1.xml"))
        let second = try String(contentsOf: unpack.appendingPathComponent("ppt/slides/slide2.xml"))
        XCTAssertTrue(first.contains("主题01")); XCTAssertTrue(second.contains("主题02 &amp; 足球"))
        XCTAssertEqual(second.components(separatedBy: "<p:grpSp>").count-1, 4)
        XCTAssertTrue(second.contains("<a:custGeom>")); XCTAssertTrue(second.contains("FFC400"))
        XCTAssertFalse(second.contains("<p:pic>")); XCTAssertFalse(second.contains("<a:blip"))
        XCTAssertEqual(updates.last?.completed, 5); XCTAssertEqual(updates.last?.fraction, 0.8)
        XCTAssertEqual(updates.map(\.fraction), updates.map(\.fraction).sorted())
    }
    func testNativePresentationCutoutsErasePriorPaintButKeepLaterPaint() {
        let green = Ink(red: 0, green: 0.5, blue: 0), white = Ink(red: 1, green: 1, blue: 1)
        func rect(_ id: Int, _ b: CGRect, _ ink: Ink) -> VectorShape {
            VectorShape(id: id, path: CGPath(rect: b, transform: nil), ink: ink)
        }
        let shapes = PresentationExporter.editableShapes(Pictogram(number: 1, shapes: [
            rect(1, CGRect(x: 0, y: 0, width: 100, height: 100), green),
            rect(2, CGRect(x: 20, y: 20, width: 60, height: 60), white),
            rect(3, CGRect(x: 40, y: 40, width: 20, height: 20), green)]))
        XCTAssertEqual(shapes.count, 2)
        XCTAssertTrue(shapes[0].path.contains(CGPoint(x: 10, y: 10)))
        XCTAssertFalse(shapes[0].path.contains(CGPoint(x: 30, y: 30)))
        XCTAssertTrue(shapes[1].path.contains(CGPoint(x: 50, y: 50)))
        XCTAssertTrue(shapes.allSatisfy { !$0.ink.isNearlyWhite && !$0.evenOdd })
    }
    func testExportProgressCountsActualFilesAndIncludesZIPStages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jobs = [SVGExportJob(name: "sample", icons: Array(try AIParser().analyze(url: fixture).pictograms.prefix(4)))]
        for layout in SVGExportLayout.allCases {
            let target = folder.appendingPathComponent(layout.rawValue)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            var updates: [SVGExportProgress] = []
            XCTAssertEqual(try SVGExporter().export(jobs, color: .black, to: target, layout: layout) { updates.append($0) }, 4)
            XCTAssertEqual(updates.map(\.completed), [0,1,2,3,4])
            XCTAssertEqual(updates.map(\.fraction), [0,0.25,0.5,0.75,1])
            XCTAssertTrue(updates.allSatisfy { $0.total == 4 })
            var archiveUpdates: [SVGExportProgress] = []
            let result = try SVGExporter().exportArchive(jobs, color: .black, to: folder.appendingPathComponent(layout.rawValue + ".zip"), layout: layout) { archiveUpdates.append($0) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
            XCTAssertEqual(archiveUpdates.last?.fraction, 1)
            XCTAssertTrue(archiveUpdates.contains { $0.phase == "打包 ZIP" && $0.fraction > 0.75 && $0.fraction < 1 })
            XCTAssertTrue(archiveUpdates.contains { $0.phase == "保存 ZIP" && $0.fraction == 0.99 })
            XCTAssertEqual(archiveUpdates.map(\.fraction), archiveUpdates.map(\.fraction).sorted())
        }
    }
    func testFlatExportAndArchiveKeepAllDocumentsInOneFolderWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let icons = Array(try AIParser().analyze(url: fixture).pictograms.prefix(4)).reversed()
        let jobs = (1...10).reversed().map { SVGExportJob(name: String(format: "素材%02d", $0), icons: Array(icons)) }
        let existing = folder.appendingPathComponent("素材01-01.svg")
        try "existing".write(to: existing, atomically: true, encoding: .utf8)
        XCTAssertEqual(try SVGExporter().export(jobs, color: .yellow, to: folder, layout: .flat), 40)
        XCTAssertEqual(try String(contentsOf: existing), "existing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("素材01-01 (2).svg").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 41)
        let result = try SVGExporter().exportArchive(jobs + [jobs[0]], color: .yellow, to: folder.appendingPathComponent("flat.zip"), layout: .flat)
        XCTAssertEqual(result.count, 44)
        let unpacked = folder.appendingPathComponent("unpacked")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", result.url.path, unpacked.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let root = unpacked.appendingPathComponent("SVG图标")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names.count, 44)
        XCTAssertTrue(names.allSatisfy { $0.hasSuffix(".svg") })
        XCTAssertTrue(names.contains("素材10-01 (2).svg"))
        for name in names {
            let xml = try XMLDocument(contentsOf: root.appendingPathComponent(name))
            let paths = try xml.nodes(forXPath: "//*[local-name()='path']").compactMap { $0 as? XMLElement }
            XCTAssertEqual(Set(paths.compactMap { $0.attribute(forName: "fill")?.stringValue }), ["#FFC400"])
        }
    }

    func testFailedFlatExportRollsBackOnlyNewFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("keep.svg")
        try "existing".write(to: existing, atomically: true, encoding: .utf8)
        let icon = try AIParser().analyze(url: fixture).pictograms[0]
        XCTAssertThrowsError(try SVGExporter().export([SVGExportJob(name: "a", icons: [icon]), SVGExportJob(name: "z/" + String(repeating: "x", count: 300), icons: [icon])], color: .black, to: folder, layout: .flat))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["keep.svg"])
        XCTAssertEqual(try String(contentsOf: existing), "existing")
    }
    private var fixture: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/p0941.ai") }
    private func material(_ stem: String) -> URL { fixture.deletingLastPathComponent().appendingPathComponent(stem + ".ai") }

    func testRunnerExcludesFooterCopyrightAndKeepsSweatAndBriefcase() throws {
        let root = try AIParser().parseDrawing(data: Data(contentsOf: material("p0008")))
        let icons = findPeople(in: root)
        XCTAssertEqual(icons.count, 4)
        XCTAssertEqual(icons.map { $0.shapes.count }, [4, 4, 6, 12])
        XCTAssertEqual(Set(icons.flatMap { $0.shapes.map(\.id) }), Set(311...336))
        XCTAssertTrue(root.allShapes.contains { $0.id == 337 }, "Copyright remains in the original drawing")
        for icon in icons { XCTAssertLessThan(icon.bounds.height, 110) }
        let original = root.children.first { $0.allShapes.map(\.id).contains(325) }!
        XCTAssertEqual(icons[3].shapes.map(\.pathData), original.allShapes.sorted { $0.id < $1.id }.map(\.pathData))
        let xml = try XMLDocument(xmlString: icons[3].svg(color: .yellow), options: [])
        XCTAssertEqual(try xml.nodes(forXPath: "//*[local-name()='path']").count, 12)
        XCTAssertFalse(icons[3].svg().contains(root.allShapes.first { $0.id == 337 }!.pathData))
    }

    func testCanoeLooseOffGridHeadsAndPaddlesAreNotFilteredAsFooter() throws {
        let icons = try AIParser().analyze(url: material("p0614")).pictograms
        XCTAssertEqual(icons.count, 13)
        XCTAssertEqual(Set(icons.flatMap { $0.shapes.map(\.id) }), Set(377...486))
        // These small heads sit below the grid and are not explicitly grouped.
        XCTAssertTrue(icons.contains { Set([471, 472, 476, 477]).isSubset(of: Set($0.shapes.map(\.id))) })
    }

    func testSoccerKeepsEveryBallAndDetachedStripedArm() throws {
        let root = try AIParser().parseDrawing(data: Data(contentsOf: material("p0004")))
        let icons = findPeople(in: root)
        XCTAssertEqual(icons.count, 5)
        XCTAssertEqual(icons.map { $0.shapes.count }, [3, 3, 5, 3, 5])
        let originals = Array(root.children.suffix(5))
        for (icon, original) in zip(icons, originals) {
            XCTAssertEqual(icon.shapes.map(\.id), original.allShapes.map(\.id).sorted())
            for shape in icon.shapes {
                XCTAssertEqual(shape.pathData, original.allShapes.first { $0.id == shape.id }?.pathData)
            }
        }
        XCTAssertEqual(icons[2].shapes.map(\.id), [317, 318, 319, 320, 321])
        let oval = icons[3].shapes.first { $0.id == 324 }!
        XCTAssertEqual(oval.bounds.width, 14.2696, accuracy: 0.0001)
        XCTAssertEqual(oval.bounds.height, 24.544, accuracy: 0.0001, "The original ball is deliberately oval")
    }

    func testBoxerOverprintMetadataAndStrokeOutlinesAreSupported() throws {
        let analysis = try AIParser().analyze(url: material("p0208"))
        XCTAssertEqual(analysis.pictograms.count, 7)
        XCTAssertEqual(analysis.pictograms.map { $0.shapes.count }, [5, 5, 5, 5, 12, 12, 12])
        XCTAssertEqual(Set(analysis.pictograms.flatMap { $0.shapes.map(\.id) }).count, 56)
        // Rounded glove/detail outlines must be actual vector paths, not omitted strokes.
        for icon in analysis.pictograms { XCTAssertTrue(icon.shapes.allSatisfy { !$0.path.isEmpty }) }
    }

    func testStrokeCapsAndOpenVersusClosedPathsKeepTheirGeometry() throws {
        func drawing(_ body: String) -> Data {
            Data(("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator\n%%EndSetup\n" + body + "\n%%PageTrailer\n").utf8)
        }
        let stroke = try AIParser().analyze(data: drawing("1 G 1 J 1 j 4 w []0 d 0 R\n10 -10 m 30 -10 L S"))
        XCTAssertEqual(stroke.shapes.count, 1)
        XCTAssertEqual(stroke.shapes[0].bounds, CGRect(x: 8, y: 8, width: 24, height: 4))
        XCTAssertTrue(stroke.shapes[0].ink.isNearlyWhite)
        let fillAndStroke = try AIParser().analyze(data: drawing("0 g 0 G 0 J 0 j 2 w []0 d\n10 -10 m 30 -10 L 30 -30 L b"))
        XCTAssertEqual(fillAndStroke.shapes.count, 2)
        XCTAssertTrue(fillAndStroke.shapes[0].segments.contains(.close))
        XCTAssertGreaterThan(fillAndStroke.shapes[1].bounds.width, fillAndStroke.shapes[0].bounds.width)
    }

    func testPDFBackedScooterPreservesAllWheelsAndHelmets() throws {
        let icons = try AIParser().analyze(url: material("p0933")).pictograms
        XCTAssertEqual(icons.count, 8)
        XCTAssertEqual(icons.map { $0.shapes.count }, [8, 8, 8, 8, 8, 8, 9, 9])
        XCTAssertEqual(Set(icons.flatMap { $0.shapes.map(\.id) }), Set(349...414))
        XCTAssertGreaterThan(icons[4].bounds.maxY, 464, "Wheels extend past the last registration row")
        XCTAssertTrue(icons.allSatisfy { !$0.svg().contains("<image") })
    }

    func testAuthorGroupsOverrideGridSlotsForNineVariantsAndWideScenes() throws {
        XCTAssertEqual(try AIParser().analyze(url: material("p0746")).pictograms.count, 9)
        let root = try AIParser().parseDrawing(data: Data(contentsOf: material("p0239")))
        let icons = findPeople(in: root)
        let wide = root.children.first { group in
            let b = group.allShapes.reduce(CGRect.null) { $0.union($1.bounds) }
            return b.width > 450 && b.width < 500 && b.minY > 100 && b.maxY < 450
        }!
        XCTAssertTrue(icons.contains { Set(wide.allShapes.map(\.id)).isSubset(of: Set($0.shapes.map(\.id))) })
    }

    func testExtraVariantsOutsideRegistrationGridKeepWholeGroups() throws {
        let root = try AIParser().parseDrawing(data: Data(contentsOf: material("p0787")))
        let icons = findPeople(in: root)
        XCTAssertEqual(icons.count, 13)
        for group in root.children.suffix(13) {
            let ids = Set(group.allShapes.map(\.id))
            XCTAssertTrue(icons.contains { ids.isSubset(of: Set($0.shapes.map(\.id))) })
        }
        XCTAssertEqual(Set(icons.flatMap { $0.shapes.map(\.id) }), Set(351...422))
    }

    func testSingleCompoundPathVariantsRemainSeparateAndComplete() throws {
        let icons = try AIParser().analyze(url: material("p0807")).pictograms
        XCTAssertEqual(icons.count, 8)
        XCTAssertEqual(icons.prefix(5).map { $0.shapes.count }, [1,1,1,1,1])
        XCTAssertEqual(Set(icons.prefix(5).flatMap { $0.shapes.map(\.id) }), Set(351...355))
    }

    func testWhiteKnockoutsStayTransparentDuringRecoloring() throws {
        let icons = try AIParser().analyze(url: material("p0903")).pictograms
        let icon = icons.first { $0.shapes.contains { $0.ink.isNearlyWhite } }!
        let whiteIDs = Set(icon.shapes.filter { $0.ink.isNearlyWhite }.map(\.pathData))
        let xml = try XMLDocument(xmlString: icon.svg(color: .yellow), options: [])
        let masks = try xml.nodes(forXPath: "//*[local-name()='mask']//*[local-name()='path']").compactMap { $0 as? XMLElement }
        XCTAssertEqual(Set(masks.compactMap { $0.attribute(forName: "d")?.stringValue }), whiteIDs)
        XCTAssertTrue(masks.allSatisfy { $0.attribute(forName: "fill")?.stringValue == "black" })
        let foreground = try xml.nodes(forXPath: "//*[local-name()='path' and not(ancestor::*[local-name()='defs'])]").compactMap { $0 as? XMLElement }
        XCTAssertTrue(foreground.allSatisfy { $0.attribute(forName: "fill")?.stringValue == "#FFC400" })
        XCTAssertFalse(icon.svg(color: .yellow).contains("<image"))
    }

    func testRealMaterialProducesEightCompleteCharacters() throws {
        let analysis = try AIParser().analyze(url: fixture)
        XCTAssertEqual(analysis.pictograms.count, 8)
        XCTAssertEqual(analysis.pictograms.map { $0.shapes.count }, [2, 2, 2, 2, 4, 4, 2, 2])
        XCTAssertEqual(Set(analysis.pictograms.flatMap { $0.shapes.map(\.id) }).count, 20)
        for icon in analysis.pictograms {
            XCTAssertTrue(icon.bounds.height > 85 && icon.bounds.height < 135)
            XCTAssertTrue(icon.bounds.width > 50 && icon.bounds.width < 80)
            XCTAssertEqual(icon.shapes.filter(\.isCircle).count, 1, "Every exported person must include a head")
        }
        XCTAssertLessThan(analysis.pictograms[0].bounds.midX, analysis.pictograms[1].bounds.midX)
        XCTAssertLessThan(analysis.pictograms[3].bounds.midY, analysis.pictograms[4].bounds.midY)
    }

    func testSVGContainsOnlySelectedVectorPathsAndPreservesHoles() throws {
        let icons = try AIParser().analyze(url: fixture).pictograms
        for icon in icons {
            let xml = try XMLDocument(xmlString: icon.svg(), options: [])
            XCTAssertEqual(xml.rootElement()?.children?.compactMap { $0 as? XMLElement }.map(\.name), Array(repeating: "path", count: icon.shapes.count))
            XCTAssertFalse(icon.svg().contains("<image"))
            XCTAssertFalse(icon.svg().contains("<rect"))
            XCTAssertFalse(icon.svg().contains("clip-path"))
        }
        // In the original suited character, the tie and buttons occupy compound-path holes.
        let suitBody = icons[4].shapes.last!
        XCTAssertGreaterThan(suitBody.segments.filter { if case .move = $0 { return true }; return false }.count, 1)
        let button = CGPoint(x: 194.4556, y: 364.1074)
        XCTAssertFalse(suitBody.path.contains(button, using: .winding), "Button remains transparent, not painted white")
    }

    func testRejectsPDFAndUnknownDrawingInstructions() throws {
        XCTAssertThrowsError(try AIParser().analyze(data: Data("%PDF-1.7\n".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("PDF 型 AI"))
        }
        var source = try String(contentsOf: fixture, encoding: .isoLatin1)
        source = source.replacingOccurrences(of: "%%EndSetup", with: "%%EndSetup\n1 0 0 1 0 0 cm")
        XCTAssertThrowsError(try AIParser().analyze(data: source.data(using: .isoLatin1)!)) { error in
            XCTAssertTrue(error.localizedDescription.contains("cm"))
        }
    }

    func testBlackAndWhiteExportsChangeInkWithoutChangingGeometry() throws {
        let icon = try AIParser().analyze(url: fixture).pictograms[0]
        for color in [ExportColor.black, .white] {
            let xml = try XMLDocument(xmlString: icon.svg(color: color), options: [])
            let paths = try xml.nodes(forXPath: "//*[local-name()='path']").compactMap { $0 as? XMLElement }
            XCTAssertEqual(paths.map { $0.attribute(forName: "d")?.stringValue }, icon.shapes.map(\.pathData))
            XCTAssertEqual(Set(paths.compactMap { $0.attribute(forName: "fill")?.stringValue }), [color == .black ? "#000000" : "#FFFFFF"])
        }
    }

    func testBatchExportPreservesExistingFilesAndSeparatesIdenticalNames() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sticksvg-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let existing = output.appendingPathComponent("p0941")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let protected = existing.appendingPathComponent("p0941-01.svg")
        try "keep existing file".write(to: protected, atomically: true, encoding: .utf8)
        let icons = try AIParser().analyze(url: fixture).pictograms
        let jobs = [SVGExportJob(name: "p0941", icons: icons), SVGExportJob(name: "p0941", icons: icons)]
        XCTAssertEqual(try SVGExporter().export(jobs, color: .original, to: output), 16)
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "keep existing file")
        for suffix in [2, 3] {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("p0941 (\(suffix))").path).count, 8)
        }
    }
    func testPaletteAcceptsCustomHexAndKeepsGeometryAndHoles() throws {
        XCTAssertEqual(ExportColor(hex: " #fa0 ")?.hex, "#FFAA00")
        XCTAssertEqual(ExportColor(hex: "1199ee")?.hex, "#1199EE")
        for invalid in ["#12345", "yellow", "#GG0000", "#000000\" onclick=\"x"] {
            XCTAssertNil(ExportColor(hex: invalid))
        }
        let icon = try AIParser().analyze(url: fixture).pictograms[4]
        for color in [ExportColor.yellow, ExportColor(hex: "#1199ee")!] {
            let xml = try XMLDocument(xmlString: icon.svg(color: color), options: [])
            let paths = try xml.nodes(forXPath: "//*[local-name()='path']").compactMap { $0 as? XMLElement }
            XCTAssertEqual(paths.map { $0.attribute(forName: "d")?.stringValue }, icon.shapes.map(\.pathData))
            XCTAssertEqual(Set(paths.compactMap { $0.attribute(forName: "fill")?.stringValue }), [color.hex!])
            XCTAssertEqual(paths.map { $0.attribute(forName: "fill-rule")?.stringValue }, icon.shapes.map { $0.evenOdd ? "evenodd" : "nonzero" })
        }
    }

    func testMergeAndSplitRoundTripPreservesEveryOriginalPath() throws {
        let icons = try AIParser().analyze(url: fixture).pictograms
        let merged = try PictogramEdits.merge(icons, ids: Set(icons.prefix(2).map(\.id)))
        XCTAssertEqual(merged.count, 7)
        let pair = try PictogramEdits.split(merged[0], shapeIDs: Set(icons[1].shapes.map(\.id)), newNumber: 9)
        XCTAssertEqual(pair.count, 2)
        XCTAssertEqual(pair[0].shapes.map(\.pathData), icons[0].shapes.map(\.pathData))
        XCTAssertEqual(pair[1].shapes.map(\.pathData), icons[1].shapes.map(\.pathData))
        XCTAssertEqual(Set((Array(merged.dropFirst()) + pair).flatMap { $0.shapes.map(\.id) }).count, 20)
        XCTAssertThrowsError(try PictogramEdits.split(icons[0], shapeIDs: Set(icons[0].shapes.map(\.id)), newNumber: 9))
        XCTAssertThrowsError(try PictogramEdits.merge(icons, ids: [icons[0].id]))
    }

    func testManualRectangleSelectsHeadAndBodyWithoutNearbyArtwork() throws {
        let analysis = try AIParser().analyze(url: fixture)
        let icon = analysis.pictograms[0]
        let ids = PictogramEdits.select(in: icon.bounds.insetBy(dx: -1, dy: -1), shapes: analysis.shapes)
        XCTAssertEqual(ids, Set(icon.shapes.map(\.id)))
        XCTAssertTrue(PictogramEdits.select(in: CGRect(x: 10000, y: 10000, width: 20, height: 20), shapes: analysis.shapes).isEmpty)
    }

    func testMissingGroupsStillExtractsEightCompleteFigures() throws {
        let source = try String(contentsOf: fixture, encoding: .isoLatin1)
        let start = source.range(of: "%%EndSetup")!.upperBound
        let end = source.range(of: "%%PageTrailer", range: start..<source.endIndex)!.lowerBound
        let body = source[start..<end].replacingOccurrences(of: #"(?m)^[uU]\r?$"#, with: "", options: .regularExpression)
        let altered = String(source[..<start]) + body + String(source[end...])
        let analysis = try AIParser().analyze(data: altered.data(using: .isoLatin1)!)
        XCTAssertEqual(analysis.pictograms.count, 8)
        XCTAssertEqual(analysis.pictograms.map { $0.shapes.count }, [2, 2, 2, 2, 4, 4, 2, 2])
        XCTAssertEqual(Set(analysis.pictograms.flatMap { $0.shapes.map(\.id) }).count, 20)
    }

    func testHorizontalGroupedFigureIsRecognized() throws {
        let icon = try AIParser().analyze(url: fixture).pictograms[0]
        func rotate(_ p: Point) -> Point { Point(x: -p.y, y: p.x) }
        let root = Group()
        root.shapes = icon.shapes.map { shape in
            let segments: [Segment] = shape.segments.map { segment in
                switch segment {
                case .move(let p): return .move(rotate(p))
                case .line(let p): return .line(rotate(p))
                case .curve(let a, let b, let c): return .curve(rotate(a), rotate(b), rotate(c))
                case .close: return .close
                }
            }
            return VectorShape(id: shape.id, segments: segments, ink: shape.ink, evenOdd: shape.evenOdd)
        }
        let results = findPeople(in: root)
        XCTAssertEqual(results.count, 1)
        XCTAssertGreaterThan(results[0].bounds.width, results[0].bounds.height)
        XCTAssertEqual(results[0].shapes.count, 2)
    }

    func testTenDocumentArchiveHasFortyRecoloredVectorSVGs() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sticksvg-zip-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let icons = Array(try AIParser().analyze(url: fixture).pictograms.prefix(4))
        let jobs = (1...10).map { SVGExportJob(name: String(format: "素材%02d", $0), icons: icons) }
        let destination = output.appendingPathComponent("图标.zip")
        let result = try SVGExporter().exportArchive(jobs, color: .yellow, to: destination)
        XCTAssertEqual(result.count, 40)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        verify.arguments = ["-tqq", result.url.path]
        verify.standardOutput = FileHandle.nullDevice
        try verify.run(); verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0, "Independent ZIP reader verifies every file checksum")
        let extracted = output.appendingPathComponent("unpacked")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", result.url.path, extracted.path]
        try unzip.run(); unzip.waitUntilExit(); XCTAssertEqual(unzip.terminationStatus, 0)
        let root = extracted.appendingPathComponent("SVG图标")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 10)
        for job in jobs {
            let folder = root.appendingPathComponent(job.name)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 4)
            for icon in icons {
                let file = folder.appendingPathComponent(String(format: "%@-%02d.svg", job.name, icon.number))
                let xml = try XMLDocument(contentsOf: file)
                let paths = try xml.nodes(forXPath: "//*[local-name()='path']").compactMap { $0 as? XMLElement }
                XCTAssertEqual(paths.map { $0.attribute(forName: "d")?.stringValue }, icon.shapes.map(\.pathData))
                XCTAssertEqual(Set(paths.compactMap { $0.attribute(forName: "fill")?.stringValue }), ["#FFC400"])
                XCTAssertEqual(xml.rootElement()?.children?.compactMap { $0 as? XMLElement }.count, paths.count)
            }
        }
        let originalArchive = try Data(contentsOf: result.url)
        let second = try SVGExporter().exportArchive([jobs[0]], color: .black, to: destination)
        XCTAssertEqual(second.url.lastPathComponent, "图标 (2).zip")
        XCTAssertEqual(try Data(contentsOf: result.url), originalArchive)
    }

}
