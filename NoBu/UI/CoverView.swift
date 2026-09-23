import SwiftUI

/// 書影。楽天・版元ドットコムへの直リンクで、読み込めなければ書名を出した無地に落ちる
/// （書影の無い本が3割ほどある）。
struct CoverView: View {
    enum Size {
        case tiny, small, medium, large
        var width: CGFloat {
            switch self {
            case .tiny: return 28
            case .small: return 84
            case .medium: return 60
            case .large: return 118
            }
        }
        var height: CGFloat { width * 1.45 }
        /// 楽天の画像は ?_ex=WxH で縮尺が変わる。一覧は小さいものを取る
        var exParam: String {
            switch self {
            case .tiny, .medium: return "200x200"
            case .small: return "300x300"
            case .large: return "600x600"
            }
        }
    }

    let url: String?
    let title: String
    var size: Size = .medium

    private var resolved: URL? {
        guard let url, !url.isEmpty else { return nil }
        guard url.contains("thumbnail.image.rakuten.co.jp") else { return URL(string: url) }
        // 既に ?_ex= が付いていれば置き換える
        let base = url.split(separator: "?").first.map(String.init) ?? url
        return URL(string: "\(base)?_ex=\(size.exParam)")
    }

    var body: some View {
        Group {
            if let resolved {
                AsyncImage(url: resolved) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .empty:
                        placeholder(showTitle: false).overlay(ProgressView().controlSize(.small))
                    default:
                        placeholder(showTitle: true)
                    }
                }
            } else {
                placeholder(showTitle: true)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
    }

    private func placeholder(showTitle: Bool) -> some View {
        ZStack {
            Color(.secondarySystemBackground)
            if showTitle, size != .tiny {
                Text(title)
                    .font(size == .large ? .caption : .system(size: 9))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(3)
            }
        }
    }
}
