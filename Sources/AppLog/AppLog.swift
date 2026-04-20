// Sources/AppLog/AppLog.swift
//
// Single source of truth for unified logging across the io.goodkind.fan ecosystem.
//
// Design note: make(category:) returns AppLog.Channel rather than os.Logger directly.
// os.Logger extensions that shadow existing overloads cause ambiguous overload errors
// when both OSLogMessage and AppLogMessage conform to ExpressibleByStringLiteral.
// AppLog.Channel exposes only AppLogMessage typed methods, so unannotated interpolation
// fails to compile (Rule 7 Guard B) without the overload ambiguity.

import CryptoKit
import Foundation
import Logging
import os

// MARK: - Privacy

/// Privacy annotation required on every interpolated value in a log message.
/// Mirrors the OSLogPrivacy API surface so call sites read identically.
public struct AppLogPrivacy: Sendable {
    public static let `public` = AppLogPrivacy(.public)
    public static let `private` = AppLogPrivacy(.private)
    public static func `private`(mask: Mask) -> AppLogPrivacy { AppLogPrivacy(.privateHash) }

    public struct Mask: Sendable {
        public static let hash = Mask()
    }

    fileprivate enum Kind { case `public`, `private`, privateHash }
    fileprivate let kind: Kind
    private init(_ kind: Kind) { self.kind = kind }

    func render(_ value: String) -> String {
        switch kind {
        case .public:
            return value
        case .private:
            return "<private>"
        case .privateHash:
            let digest = SHA256.hash(data: Data(value.utf8))
            let hex = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            return "<private:\(hex)>"
        }
    }
}

// MARK: - AppLogMessage

/// Message type whose StringInterpolation REQUIRES a privacy: argument on every interpolated value.
/// Unannotated interpolation (e.g. log.info("x=\(val)")) fails to compile.
public struct AppLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    public let rendered: String

    public init(stringLiteral value: String) {
        self.rendered = value
    }

    public init(stringInterpolation: StringInterpolation) {
        self.rendered = stringInterpolation.buffer
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var buffer = ""

        public init(literalCapacity: Int, interpolationCount: Int) {
            buffer.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            buffer += literal
        }

        public mutating func appendInterpolation(_ value: String, privacy: AppLogPrivacy) {
            buffer += privacy.render(value)
        }

        public mutating func appendInterpolation(_ value: Int, privacy: AppLogPrivacy) {
            buffer += privacy.render(String(value))
        }

        public mutating func appendInterpolation(_ value: UInt, privacy: AppLogPrivacy) {
            buffer += privacy.render(String(value))
        }

        public mutating func appendInterpolation(_ value: UInt32, privacy: AppLogPrivacy) {
            buffer += privacy.render(String(value))
        }

        public mutating func appendInterpolation(_ value: Double, privacy: AppLogPrivacy) {
            buffer += privacy.render(String(value))
        }

        public mutating func appendInterpolation(_ value: Float, privacy: AppLogPrivacy) {
            buffer += privacy.render(String(value))
        }

        public mutating func appendInterpolation(_ value: Bool, privacy: AppLogPrivacy) {
            buffer += privacy.render(value ? "true" : "false")
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(
            _ value: T, privacy: AppLogPrivacy
        ) {
            buffer += privacy.render(value.description)
        }
    }
}

// MARK: - AppLog namespace

public enum AppLog {
    nonisolated(unsafe) private static var _subsystem: String = "io.goodkind.fan"

    /// Call as the first statement in every executable target entry point, before any other logic.
    /// Idempotent. Safe to call more than once. Must not throw.
    public static func bootstrap(subsystem: String) {
        _subsystem = subsystem
        LoggingSystem.bootstrap { label in
            OSLogHandler(subsystem: subsystem, category: label)
        }
        let startLog = make(category: "AppLog")
        startLog.notice(
            "process.started subsystem=\(subsystem, privacy: .public) version=\(BuildInfo.version, privacy: .public) commit=\(BuildInfo.commit, privacy: .public) buildHash=\(BuildInfo.buildHash(), privacy: .public)"
        )
    }

    /// Returns a log channel scoped to the given category.
    /// Declare one per source file at file scope: private let log = AppLog.make(category: "MyType")
    public static func make(category: String) -> Channel {
        Channel(logger: os.Logger(subsystem: _subsystem, category: category))
    }

    /// Returns a signposter for bracketing operations that may exceed 50 ms.
    @available(macOS 12, *)
    public static func signposter(category: String = "Performance") -> OSSignposter {
        OSSignposter(subsystem: _subsystem, category: category)
    }

    // MARK: - Channel

    /// Thin wrapper around os.Logger that accepts only AppLogMessage, enforcing privacy annotations
    /// at compile time. Every log method requires a fully annotated AppLogMessage argument.
    public struct Channel: Sendable {
        private let logger: os.Logger

        init(logger: os.Logger) {
            self.logger = logger
        }

        public func debug(_ message: AppLogMessage) {
            logger.debug("\(message.rendered, privacy: .public)")
        }

        public func info(_ message: AppLogMessage) {
            logger.info("\(message.rendered, privacy: .public)")
        }

        public func notice(_ message: AppLogMessage) {
            logger.notice("\(message.rendered, privacy: .public)")
        }

        public func error(_ message: AppLogMessage) {
            logger.error("\(message.rendered, privacy: .public)")
        }

        public func fault(_ message: AppLogMessage) {
            logger.fault("\(message.rendered, privacy: .public)")
        }
    }
}

// MARK: - swift-log bridge

/// Routes every transitive swift-log consumer through os.Logger so events land in the unified log.
/// Installed by AppLog.bootstrap inside LoggingSystem.bootstrap.
private struct OSLogHandler: LogHandler, Sendable {
    let logger: os.Logger
    var metadata: Logging.Logger.Metadata = [:]
    var logLevel: Logging.Logger.Level = .trace

    init(subsystem: String, category: String) {
        self.logger = os.Logger(subsystem: subsystem, category: category)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let type: OSLogType = switch event.level {
        case .trace, .debug: .debug
        case .info, .notice: .info
        case .warning, .error: .error
        case .critical: .fault
        }
        var merged = metadata
        if let m = event.metadata {
            merged.merge(m) { _, new in new }
        }
        let suffix = merged.isEmpty ? "" : " meta=\(merged.description)"
        logger.log(
            level: type,
            "\(event.message.description, privacy: .public)\(suffix, privacy: .public)"
        )
    }
}
