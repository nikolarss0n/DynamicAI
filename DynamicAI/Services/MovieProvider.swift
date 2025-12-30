import Foundation

// MARK: - TMDB Configuration

struct TMDBConfig {
    static let baseURL = "https://api.themoviedb.org/3"
    static let imageBaseURL = "https://image.tmdb.org/t/p"
    static let posterSize = "/w500"
    static let backdropSize = "/w780"

    // Get API key from environment or keys file
    static var apiKey: String? {
        // Try environment variable first
        if let key = ProcessInfo.processInfo.environment["TMDB_API_KEY"] {
            return key
        }

        // Try ~/.interview-master-keys file
        let keysPath = NSString("~/.interview-master-keys").expandingTildeInPath
        if let content = try? String(contentsOfFile: keysPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("TMDB_API_KEY=") {
                    return String(trimmed.dropFirst("TMDB_API_KEY=".count))
                }
            }
        }
        return nil
    }
}

// MARK: - Movie Provider

actor MovieProvider {
    private let cache = ResponseCache()
    private let session = URLSession.shared

    private static func log(_ message: String) {
        let logPath = "/tmp/dynamicai.log"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    // MARK: - Search Movies

    func search(query: String, type: String, filter: String? = nil) async -> ToolExecutionResult {
        guard let apiKey = TMDBConfig.apiKey else {
            return .error("TMDB_API_KEY not set")
        }

        Self.log("🎬 MovieProvider.search - query: '\(query)', type: '\(type)', filter: '\(filter ?? "none")'")

        // SMART ROUTING: If query contains keywords, always search
        // This handles cases where Claude sends type=upcoming with query=marvel
        let hasKeyword = !query.isEmpty && query.lowercased() != "movies" && query.lowercased() != "movie"

        if hasKeyword {
            // Derive filter from type if not explicitly set
            let effectiveFilter = filter ?? (type == "upcoming" ? "upcoming" : (type == "now_playing" ? "now_playing" : nil))
            Self.log("🔄 Using keyword search with filter: \(effectiveFilter ?? "none")")
            return await searchByKeyword(query: query, filter: effectiveFilter, apiKey: apiKey)
        }

        // For browse types (no specific keyword), get the list
        // Use discover API for upcoming to get proper date filtering and sorting
        let dateFormatter = ISO8601DateFormatter()
        let today = String(dateFormatter.string(from: Date()).prefix(10)) // YYYY-MM-DD

        let urlString: String
        switch type {
        case "upcoming":
            // Use discover API: future releases only, sorted by release date
            let sixMonthsLater = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
            let maxDate = String(dateFormatter.string(from: sixMonthsLater).prefix(10))
            urlString = "\(TMDBConfig.baseURL)/discover/movie?api_key=\(apiKey)&language=en-US&primary_release_date.gte=\(today)&primary_release_date.lte=\(maxDate)&sort_by=primary_release_date.asc&with_release_type=2|3"
        case "now_playing":
            urlString = "\(TMDBConfig.baseURL)/movie/now_playing?api_key=\(apiKey)&language=en-US"
        case "popular":
            urlString = "\(TMDBConfig.baseURL)/movie/popular?api_key=\(apiKey)&language=en-US"
        default:
            urlString = "\(TMDBConfig.baseURL)/movie/popular?api_key=\(apiKey)&language=en-US"
        }

        Self.log("🎬 Browse URL: \(urlString)")

        // Check cache
        if let cached = await cache.get(urlString),
           let response = try? JSONDecoder().decode(TMDBMovieResponse.self, from: cached) {
            let movies = response.results.prefix(5).map { $0.toMovieInfo() }
            return .movies(Array(movies))
        }

        do {
            guard let url = URL(string: urlString) else {
                return .error("Invalid URL")
            }

            let (data, _) = try await session.data(from: url)
            await cache.set(urlString, data: data)

            let response = try JSONDecoder().decode(TMDBMovieResponse.self, from: data)
            let movies = response.results.prefix(5).map { $0.toMovieInfo() }

            // Fetch trailers for first result
            if let firstMovie = movies.first {
                let movieWithTrailer = await fetchTrailer(for: firstMovie)
                var updatedMovies = Array(movies)
                updatedMovies[0] = movieWithTrailer
                return .movies(updatedMovies)
            }

            return .movies(Array(movies))
        } catch {
            return .error("TMDB error: \(error.localizedDescription)")
        }
    }

    // MARK: - Search by Keyword with Optional Date Filter

    // Known franchise/studio mappings to TMDB company IDs
    private static let studioMappings: [String: Int] = [
        "marvel": 420,      // Marvel Studios
        "mcu": 420,
        "dc": 429,          // DC Entertainment
        "dceu": 429,
        "pixar": 3,         // Pixar
        "disney": 2,        // Walt Disney Pictures
        "ghibli": 10342,    // Studio Ghibli
        "dreamworks": 521   // DreamWorks
    ]

    private func searchByKeyword(query: String, filter: String?, apiKey: String) async -> ToolExecutionResult {
        let lowerQuery = query.lowercased()

        // Check if this is a studio/franchise search
        if let companyId = Self.studioMappings[lowerQuery] {
            return await discoverByCompany(companyId: companyId, filter: filter, apiKey: apiKey)
        }

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let urlString = "\(TMDBConfig.baseURL)/search/movie?api_key=\(apiKey)&language=en-US&query=\(encodedQuery)&page=1"
        Self.log("🔍 TMDB search URL: \(urlString)")

        do {
            guard let url = URL(string: urlString) else {
                return .error("Invalid URL")
            }

            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(TMDBMovieResponse.self, from: data)

            var movies = response.results.map { $0.toMovieInfo() }

            // Apply date filter if specified
            if let filter = filter {
                let today = Date()
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"

                movies = movies.filter { movie in
                    guard let releaseDate = dateFormatter.date(from: movie.releaseDate) else {
                        return false
                    }

                    switch filter {
                    case "upcoming":
                        return releaseDate > today
                    case "now_playing":
                        let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: today) ?? today
                        return releaseDate <= today && releaseDate >= threeMonthsAgo
                    default:
                        return true
                    }
                }

                // Sort by release date for upcoming (earliest first)
                if filter == "upcoming" {
                    movies.sort { m1, m2 in
                        guard let d1 = dateFormatter.date(from: m1.releaseDate),
                              let d2 = dateFormatter.date(from: m2.releaseDate) else {
                            return false
                        }
                        return d1 < d2
                    }
                }
            }

            // Take top 5 results
            let topMovies = Array(movies.prefix(5))

            // Fetch trailers for all movies
            var moviesWithTrailers: [MovieInfo] = []
            for movie in topMovies {
                let movieWithTrailer = await fetchTrailer(for: movie)
                moviesWithTrailers.append(movieWithTrailer)
            }

            return .movies(moviesWithTrailers)
        } catch {
            return .error("TMDB error: \(error.localizedDescription)")
        }
    }

    // MARK: - Discover by Company (Studio/Franchise)

    private func discoverByCompany(companyId: Int, filter: String?, apiKey: String) async -> ToolExecutionResult {
        let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10)) // YYYY-MM-DD

        // Apply date filter and appropriate sorting
        var urlString: String
        if filter == "upcoming" {
            let sixMonthsLater = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
            let maxDate = String(ISO8601DateFormatter().string(from: sixMonthsLater).prefix(10))
            urlString = "\(TMDBConfig.baseURL)/discover/movie?api_key=\(apiKey)&language=en-US&with_companies=\(companyId)&primary_release_date.gte=\(today)&primary_release_date.lte=\(maxDate)&sort_by=primary_release_date.asc"
        } else if filter == "now_playing" {
            let threeMonthsAgo = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
            let threeMonthsAgoStr = String(ISO8601DateFormatter().string(from: threeMonthsAgo).prefix(10))
            urlString = "\(TMDBConfig.baseURL)/discover/movie?api_key=\(apiKey)&language=en-US&with_companies=\(companyId)&primary_release_date.lte=\(today)&primary_release_date.gte=\(threeMonthsAgoStr)&sort_by=primary_release_date.desc"
        } else {
            urlString = "\(TMDBConfig.baseURL)/discover/movie?api_key=\(apiKey)&language=en-US&with_companies=\(companyId)&sort_by=popularity.desc"
        }

        Self.log("🔍 TMDB discover URL: \(urlString)")

        do {
            guard let url = URL(string: urlString) else {
                return .error("Invalid URL")
            }

            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(TMDBMovieResponse.self, from: data)

            let movies = Array(response.results.prefix(5).map { $0.toMovieInfo() })

            // Fetch trailers for all movies
            var moviesWithTrailers: [MovieInfo] = []
            for movie in movies {
                let movieWithTrailer = await fetchTrailer(for: movie)
                moviesWithTrailers.append(movieWithTrailer)
            }

            return .movies(moviesWithTrailers)
        } catch {
            return .error("TMDB error: \(error.localizedDescription)")
        }
    }

    // MARK: - Fetch Trailer

    private func fetchTrailer(for movie: MovieInfo) async -> MovieInfo {
        guard let apiKey = TMDBConfig.apiKey else {
            Self.log("⚠️ No API key for trailer fetch")
            return movie
        }

        let urlString = "\(TMDBConfig.baseURL)/movie/\(movie.id)/videos?api_key=\(apiKey)"

        do {
            guard let url = URL(string: urlString) else { return movie }
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(TMDBVideoResponse.self, from: data)

            Self.log("🎬 Videos for \(movie.title): \(response.results.count) found")

            // Find YouTube trailer
            if let trailer = response.results.first(where: { $0.site == "YouTube" && $0.type == "Trailer" }) {
                let trailerURL = URL(string: "https://www.youtube.com/watch?v=\(trailer.key)")
                Self.log("✅ Trailer found for \(movie.title): \(trailerURL?.absoluteString ?? "nil")")
                return MovieInfo(
                    id: movie.id,
                    title: movie.title,
                    overview: movie.overview,
                    posterURL: movie.posterURL,
                    trailerURL: trailerURL,
                    releaseDate: movie.releaseDate,
                    rating: movie.rating
                )
            } else {
                // Try any YouTube video if no trailer
                if let video = response.results.first(where: { $0.site == "YouTube" }) {
                    let videoURL = URL(string: "https://www.youtube.com/watch?v=\(video.key)")
                    Self.log("📹 Using video (not trailer) for \(movie.title): \(video.type)")
                    return MovieInfo(
                        id: movie.id,
                        title: movie.title,
                        overview: movie.overview,
                        posterURL: movie.posterURL,
                        trailerURL: videoURL,
                        releaseDate: movie.releaseDate,
                        rating: movie.rating
                    )
                }
                Self.log("⚠️ No YouTube videos for \(movie.title)")
            }
        } catch {
            Self.log("❌ Failed to fetch trailer for \(movie.title): \(error)")
        }

        return movie
    }

    // MARK: - Get Movie Details

    func getMovieDetails(id: Int) async -> MovieInfo? {
        guard let apiKey = TMDBConfig.apiKey else { return nil }

        let urlString = "\(TMDBConfig.baseURL)/movie/\(id)?api_key=\(apiKey)&language=en-US&append_to_response=videos"

        do {
            guard let url = URL(string: urlString) else { return nil }
            let (data, _) = try await session.data(from: url)
            let movie = try JSONDecoder().decode(TMDBMovie.self, from: data)
            return movie.toMovieInfo()
        } catch {
            print("Failed to fetch movie details: \(error)")
            return nil
        }
    }
}

// MARK: - TMDB Response Models

struct TMDBMovieResponse: Codable {
    let page: Int
    let results: [TMDBMovie]
    let totalResults: Int
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalResults = "total_results"
        case totalPages = "total_pages"
    }
}

struct TMDBMovie: Codable {
    let id: Int
    let title: String
    let overview: String
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double
    let videos: TMDBVideoResponse?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, videos
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case voteAverage = "vote_average"
    }

    func toMovieInfo() -> MovieInfo {
        var posterURL: URL?
        if let path = posterPath {
            posterURL = URL(string: "\(TMDBConfig.imageBaseURL)\(TMDBConfig.posterSize)\(path)")
        }

        var trailerURL: URL?
        if let trailer = videos?.results.first(where: { $0.site == "YouTube" && $0.type == "Trailer" }) {
            trailerURL = URL(string: "https://www.youtube.com/watch?v=\(trailer.key)")
        }

        return MovieInfo(
            id: id,
            title: title,
            overview: overview,
            posterURL: posterURL,
            trailerURL: trailerURL,
            releaseDate: releaseDate ?? "TBA",
            rating: voteAverage
        )
    }
}

struct TMDBVideoResponse: Codable {
    let results: [TMDBVideo]
}

struct TMDBVideo: Codable {
    let key: String
    let site: String
    let type: String
    let name: String
}
