import SwiftUI

/// ChatGPT's compose mark, from OpenAI's Apps SDK UI icon set.
///
/// Source: openai/apps-sdk-ui, `src/components/Icon/svg/PencilSquare.tsx`,
/// MIT licence, Copyright 2025 OpenAI. The path is theirs, verbatim; the
/// parser below is ours, and covers only the five commands this one uses.
///
/// Carried as a path rather than an asset so it stays a shape: it takes the
/// foreground colour, scales to any size without a second export, and can be
/// centred on the part of itself that matters.
struct PencilSquareMark: Shape {
    private static let commands = SVGPath.parse(Self.data)

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let transform = CGAffineTransform(
            translationX: rect.midX - side / 2,
            y: rect.midY - side / 2
        ).scaledBy(x: scale, y: scale)
        return SVGPath.build(Self.commands).applying(transform)
    }

    private static let data = """
        M15.6729 3.91275C16.8918 2.6938 18.8682 2.6938 20.0871 3.91275C21.3061 5.1317 21.3061 7.10801 20.0871 8.32696L14.1499 14.2642C13.3849 15.0291 12.3925 15.5254 11.3215 15.6784L9.14142 15.9898C8.82983 16.0343 8.51546 15.9295 8.29289 15.707C8.07033 15.4844 7.96554 15.17 8.01005 14.8584L8.32149 12.6784C8.47449 11.6074 8.97072 10.6149 9.7357 9.84994L15.6729 3.91275ZM18.6729 5.32696C18.235 4.88906 17.525 4.88906 17.0871 5.32696L11.1499 11.2642C10.6909 11.7231 10.3932 12.3186 10.3014 12.9612L10.1785 13.8213L11.0386 13.6985C11.6812 13.6067 12.2767 13.3089 12.7357 12.8499L18.6729 6.91275C19.1108 6.47485 19.1108 5.76486 18.6729 5.32696ZM11 3.99916C11.0004 4.55145 10.5531 4.99951 10.0008 4.99994C9.00227 5.00072 8.29769 5.00815 7.74651 5.06052C7.20685 5.11179 6.88488 5.20104 6.63803 5.32682C6.07354 5.61444 5.6146 6.07339 5.32698 6.63787C5.19279 6.90123 5.10062 7.24891 5.05118 7.85408C5.00078 8.47092 5 9.26324 5 10.3998V13.5998C5 14.7364 5.00078 15.5288 5.05118 16.1456C5.10062 16.7508 5.19279 17.0985 5.32698 17.3618C5.6146 17.9263 6.07354 18.3852 6.63803 18.6729C6.90138 18.807 7.24907 18.8992 7.85424 18.9487C8.47108 18.9991 9.26339 18.9998 10.4 18.9998H13.6C14.7366 18.9998 15.5289 18.9991 16.1458 18.9487C16.7509 18.8992 17.0986 18.807 17.362 18.6729C17.9265 18.3852 18.3854 17.9263 18.673 17.3618C18.7988 17.115 18.8881 16.793 18.9393 16.2533C18.9917 15.7021 18.9991 14.9976 18.9999 13.9991C19.0003 13.4468 19.4484 12.9994 20.0007 12.9998C20.553 13.0003 21.0003 13.4483 20.9999 14.0006C20.9991 14.9788 20.9932 15.7807 20.9304 16.4425C20.8664 17.1159 20.7385 17.7135 20.455 18.2698C19.9757 19.2106 19.2108 19.9755 18.27 20.4549C17.6777 20.7567 17.0375 20.8825 16.3086 20.942C15.6008 20.9999 14.7266 20.9999 13.6428 20.9998H10.3572C9.27339 20.9999 8.39925 20.9999 7.69138 20.942C6.96253 20.8825 6.32234 20.7567 5.73005 20.4549C4.78924 19.9755 4.02433 19.2106 3.54497 18.2698C3.24318 17.6775 3.11737 17.0373 3.05782 16.3085C2.99998 15.6006 2.99999 14.7264 3 13.6426V10.357C2.99999 9.27325 2.99998 8.3991 3.05782 7.69122C3.11737 6.96237 3.24318 6.32218 3.54497 5.72989C4.02433 4.78908 4.78924 4.02418 5.73005 3.54481C6.28633 3.26137 6.88399 3.13346 7.55735 3.06948C8.21919 3.0066 9.02103 3.00071 9.99922 2.99994C10.5515 2.99951 10.9996 3.44688 11 3.99916Z
        """
}

/// The smallest SVG path reader that will do: absolute and relative move,
/// line, horizontal, vertical, cubic and close. Anything else is refused
/// loudly rather than drawn wrongly.
enum SVGPath {
    enum Segment {
        case move(CGPoint)
        case line(CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
        case close
    }

    static func build(_ segments: [Segment]) -> Path {
        var path = Path()
        for segment in segments {
            switch segment {
            case let .move(p): path.move(to: p)
            case let .line(p): path.addLine(to: p)
            case let .cubic(c1, c2, p): path.addCurve(to: p, control1: c1, control2: c2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func parse(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var numbers: [CGFloat] = []
        var command: Character = "M"
        var cursor = CGPoint.zero
        var start = CGPoint.zero

        func flush() {
            var i = 0
            func next() -> CGFloat { defer { i += 1 }; return numbers[i] }
            while i < numbers.count {
                switch command {
                case "M", "m":
                    let x = next(), y = next()
                    cursor = command == "M" ? CGPoint(x: x, y: y)
                        : CGPoint(x: cursor.x + x, y: cursor.y + y)
                    start = cursor
                    segments.append(.move(cursor))
                    // A second pair after a move is a line, per the spec.
                    command = command == "M" ? "L" : "l"
                case "L", "l":
                    let x = next(), y = next()
                    cursor = command == "L" ? CGPoint(x: x, y: y)
                        : CGPoint(x: cursor.x + x, y: cursor.y + y)
                    segments.append(.line(cursor))
                case "H", "h":
                    let x = next()
                    cursor = CGPoint(x: command == "H" ? x : cursor.x + x, y: cursor.y)
                    segments.append(.line(cursor))
                case "V", "v":
                    let y = next()
                    cursor = CGPoint(x: cursor.x, y: command == "V" ? y : cursor.y + y)
                    segments.append(.line(cursor))
                case "C", "c":
                    let base = command == "C" ? CGPoint.zero : cursor
                    let c1 = CGPoint(x: base.x + next(), y: base.y + next())
                    let c2 = CGPoint(x: base.x + next(), y: base.y + next())
                    let end = CGPoint(x: base.x + next(), y: base.y + next())
                    segments.append(.cubic(c1, c2, end))
                    cursor = end
                default:
                    assertionFailure("SVGPath: unsupported command \(command)")
                    return
                }
            }
            numbers.removeAll()
        }

        var buffer = ""
        func takeNumber() {
            if let value = Double(buffer) { numbers.append(CGFloat(value)) }
            buffer = ""
        }

        for character in text {
            if character.isLetter {
                takeNumber()
                flush()
                if character == "Z" || character == "z" {
                    segments.append(.close)
                    cursor = start
                } else {
                    command = character
                }
            } else if character == "-" && !buffer.isEmpty && !buffer.hasSuffix("e") {
                takeNumber()
                buffer = "-"
            } else if character == "," || character == " " || character == "\n" {
                takeNumber()
            } else {
                buffer.append(character)
            }
        }
        takeNumber()
        flush()
        return segments
    }
}
