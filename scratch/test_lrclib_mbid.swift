import Foundation
let url = URL(string: "https://lrclib.net/api/get?artist_name=Coldplay&track_name=Yellow&duration=266")!
let group = DispatchGroup()
group.enter()
URLSession.shared.dataTask(with: url) { data, _, _ in
    if let data = data, let str = String(data: data, encoding: .utf8) { print(str) }
    group.leave()
}.resume()
group.wait()
