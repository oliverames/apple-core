// SPDX-License-Identifier: GPL-3.0-or-later
//
// What Messages is likely to do with an address, and what that is not.
//
// Apple gives no public way to ask "will this send as iMessage?", let alone
// "will it arrive". The honest substitute is history: how this Mac's own
// Messages database has routed that address before. That is a good predictor
// and a bad guarantee, and the difference matters enough that the two are
// separate fields here rather than one confident answer.
//
// Nothing in this file can send anything. It turns observations the reader
// collected into a classification, so the wording cannot drift and can be
// tested without a Messages database.

import Foundation

/// One address as chat.db records it.
public struct MessagesRouteObservation: Sendable, Equatable {
    /// The handle exactly as Messages stores it.
    public let handle: String
    /// `handle.service`: the service this row was registered under, usually
    /// "iMessage" or "SMS". Registration is not the same as ever having sent
    /// anything.
    public let registeredService: String?
    /// The service of the most recent message this Mac sent to the handle,
    /// which is the strongest evidence available.
    public let lastOutgoingService: String?
    public let lastMessageDate: Date?
    public let messageCount: Int

    public init(
        handle: String,
        registeredService: String? = nil,
        lastOutgoingService: String? = nil,
        lastMessageDate: Date? = nil,
        messageCount: Int = 0
    ) {
        self.handle = handle
        self.registeredService = registeredService
        self.lastOutgoingService = lastOutgoingService
        self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount
    }
}

/// How strong the evidence behind a prediction is.
public enum MessagesRouteConfidence: String, Sendable, Equatable {
    /// This Mac has actually sent to the address over that service.
    case observed
    /// Only the handle's registration says so; nothing has been sent.
    case registered
    /// Messages has seen the address but its routing is inconsistent.
    case mixed
    /// Nothing on this Mac says anything about the address.
    case none
}

public struct MessagesRouteAssessment: Sendable, Equatable {
    /// "iMessage", "SMS", or nil when there is nothing to go on.
    public let likelyService: String?
    public let confidence: MessagesRouteConfidence
    public let summary: String
    /// The standing caveat. Always present, never conditional: no reading of
    /// chat.db establishes that a message will be delivered.
    public let deliveryCaveat: String
    public let observations: [MessagesRouteObservation]

    public init(
        likelyService: String?,
        confidence: MessagesRouteConfidence,
        summary: String,
        deliveryCaveat: String,
        observations: [MessagesRouteObservation]
    ) {
        self.likelyService = likelyService
        self.confidence = confidence
        self.summary = summary
        self.deliveryCaveat = deliveryCaveat
        self.observations = observations
    }
}

public enum MessagesRouteDiagnostic {
    public static let deliveryCaveat =
        "This is how Messages on this Mac has routed the address before, not a guarantee of delivery. "
        + "The recipient may have turned iMessage off, changed number, or be unreachable, and Apple Core "
        + "cannot confirm that any message arrived."

    public static func normalizeService(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch trimmed {
        case "": return nil
        case "imessage": return "iMessage"
        case "sms", "mms": return "SMS"
        default: return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public static func assess(
        address: String,
        observations: [MessagesRouteObservation]
    ) -> MessagesRouteAssessment {
        guard !observations.isEmpty else {
            return MessagesRouteAssessment(
                likelyService: nil,
                confidence: .none,
                summary:
                    "Messages on this Mac has no conversation with \(address), so there is nothing to "
                    + "predict routing from. A send would start a new conversation and Messages would "
                    + "choose the service itself.",
                deliveryCaveat: deliveryCaveat,
                observations: observations
            )
        }

        let sentServices = Set(observations.compactMap { normalizeService($0.lastOutgoingService) })
        let registeredServices = Set(observations.compactMap { normalizeService($0.registeredService) })

        if sentServices.count == 1, let service = sentServices.first {
            let recent = observations.compactMap(\.lastMessageDate).max()
            let when = recent.map { " The last exchange was \(format($0))." } ?? ""
            return MessagesRouteAssessment(
                likelyService: service,
                confidence: .observed,
                summary:
                    "This Mac last sent to \(address) as \(service), so a new message would most likely "
                    + "route the same way.\(when)",
                deliveryCaveat: deliveryCaveat,
                observations: observations
            )
        }

        if sentServices.count > 1 {
            return MessagesRouteAssessment(
                likelyService: nil,
                confidence: .mixed,
                summary:
                    "This Mac has sent to \(address) as both "
                    + sentServices.sorted().joined(separator: " and ")
                    + ", so which service a new message uses cannot be predicted from history alone.",
                deliveryCaveat: deliveryCaveat,
                observations: observations
            )
        }

        if registeredServices.count == 1, let service = registeredServices.first {
            return MessagesRouteAssessment(
                likelyService: service,
                confidence: .registered,
                summary:
                    "\(address) is known to Messages as a \(service) address, but nothing has been sent "
                    + "to it from this Mac, so the routing is inferred from that registration rather "
                    + "than observed.",
                deliveryCaveat: deliveryCaveat,
                observations: observations
            )
        }

        if registeredServices.count > 1 {
            return MessagesRouteAssessment(
                likelyService: nil,
                confidence: .mixed,
                summary:
                    "\(address) is registered with Messages under more than one service ("
                    + registeredServices.sorted().joined(separator: ", ")
                    + ") and nothing has been sent to it from this Mac.",
                deliveryCaveat: deliveryCaveat,
                observations: observations
            )
        }

        return MessagesRouteAssessment(
            likelyService: nil,
            confidence: .none,
            summary:
                "Messages knows \(address) but records no service for it, so there is nothing to predict "
                + "routing from.",
            deliveryCaveat: deliveryCaveat,
            observations: observations
        )
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
