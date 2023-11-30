import Foundation
import Metrics
@preconcurrency import RoutingKit
import NIOCore
import NIOHTTP1
import Logging

/// Vapor's main `Responder` type. Combines configured middleware + router to create a responder.
internal struct DefaultResponder: AsyncResponder {
    private let router: TrieRouter<CachedRoute>
    private let notFoundResponder: AsyncResponder
    private let reportMetrics: Bool

    private struct CachedRoute {
        let route: SendableRoute
        let responder: AsyncResponder
    }

    /// Creates a new `ApplicationResponder`
    public init(routes: Routes, middleware: [AsyncMiddleware] = [], reportMetrics: Bool = true) {
        let options = routes.caseInsensitive ?
            Set(arrayLiteral: TrieRouter<CachedRoute>.ConfigurationOption.caseInsensitive) : []
        let router = TrieRouter(CachedRoute.self, options: options)
        
        for route in routes.sendableAll {
            // Make a copy of the route to cache middleware chaining.
            let cached = CachedRoute(
                route: route,
                responder: middleware.makeAsyncResponder(chainingTo: route.responder)
            )
            
            // remove any empty path components
            let path = route.path.filter { component in
                switch component {
                case .constant(let string):
                    return string != ""
                default:
                    return true
                }
            }
            
            // If the route isn't explicitly a HEAD route,
            // and it's made up solely of .constant components,
            // register a HEAD route with the same path
            if route.method == .GET &&
                route.path.allSatisfy({ component in
                    if case .constant(_) = component { return true }
                    return false
            }) {
                let headRoute = SendableRoute(
                    method: .HEAD,
                    path: route.path,
                    responder: middleware.makeAsyncResponder(chainingTo: HeadResponder()),
                    requestType: route.requestType,
                    responseType: route.responseType)

                let headCachedRoute = CachedRoute(route: headRoute, responder: middleware.makeAsyncResponder(chainingTo: HeadResponder()))

                router.register(headCachedRoute, at: [.constant(HTTPMethod.HEAD.string)] + path)
            }
            
            router.register(cached, at: [.constant(route.method.string)] + path)
        }
        self.router = router
        self.notFoundResponder = middleware.makeAsyncResponder(chainingTo: NotFoundResponder())
        self.reportMetrics = reportMetrics
    }

    /// See `AsyncResponder`    
    func respond(to request: Request) async throws -> Response {
        let startTime = DispatchTime.now().uptimeNanoseconds
        do {
            let response: Response
            if let cachedRoute = self.getRoute(for: request) {
                request.sendableRoute = cachedRoute.route
                response = try await cachedRoute.responder.respond(to: request)
            } else {
                response = try await self.notFoundResponder.respond(to: request)
            }
            if self.reportMetrics {
                self.updateMetrics(
                    for: request,
                    startTime: startTime,
                    statusCode: response.status.code
                )
            }
            return response
        } catch {
            // This should never really be hit, we should always have the error caught by
            // the error middleware, but in case we don't have it added allow NIO to handle
            if self.reportMetrics {
                self.updateMetrics(
                    for: request,
                    startTime: startTime,
                    statusCode: HTTPStatus.internalServerError.code
                )
            }
            throw error
        }
    }
    
    /// Gets a `Route` from the underlying `TrieRouter`.
    private func getRoute(for request: Request) -> CachedRoute? {
        let pathComponents = request.url.path
            .split(separator: "/")
            .map(String.init)
        
        // If it's a HEAD request and a HEAD route exists, return that route...
        if request.method == .HEAD, let route = self.router.route(
            path: [HTTPMethod.HEAD.string] + pathComponents,
            parameters: &request.parameters
        ) {
            return route
        }

        // ...otherwise forward HEAD requests to GET route
        let method = (request.method == .HEAD) ? .GET : request.method
        
        return self.router.route(
            path: [method.string] + pathComponents,
            parameters: &request.parameters
        )
    }

    /// Records the requests metrics.
    private func updateMetrics(
        for request: Request,
        startTime: UInt64,
        statusCode: UInt
    ) {
        let pathForMetrics: String
        let methodForMetrics: String
        if let route = request.sendableRoute {
            // We don't use route.description here to avoid duplicating the method in the path
            pathForMetrics = "/\(route.path.map { "\($0)" }.joined(separator: "/"))"
            methodForMetrics = request.method.string
        } else {
            // If the route is undefined (i.e. a 404 and not something like /users/:userID
            // We rewrite the path and the method to undefined to avoid DOSing the
            // application and any downstream metrics systems. Otherwise an attacker
            // could spam the service with unlimited requests and exhaust the system
            // with unlimited timers/counters
            pathForMetrics = "vapor_route_undefined"
            methodForMetrics = "undefined"
        }
        let dimensions = [
            ("method", methodForMetrics),
            ("path", pathForMetrics),
            ("status", statusCode.description),
        ]
        Counter(label: "http_requests_total", dimensions: dimensions).increment()
        if statusCode >= 500 {
            Counter(label: "http_request_errors_total", dimensions: dimensions).increment()
        }
        Timer(
            label: "http_request_duration_seconds",
            dimensions: dimensions,
            preferredDisplayUnit: .seconds
        ).recordNanoseconds(DispatchTime.now().uptimeNanoseconds - startTime)
    }
}

private struct HeadResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response {
        Response(status: .ok)
    }
}

private struct NotFoundResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response {
        throw RouteNotFound()
    }
}

struct RouteNotFound: Error {}

extension RouteNotFound: AbortError {    
    var status: HTTPResponseStatus {
        .notFound
    }
}

extension RouteNotFound: DebuggableError {
    var logLevel: Logger.Level { 
        .debug
    }
}
