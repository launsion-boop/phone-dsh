// SPDX-License-Identifier: MIT

import Foundation
import HealthKit

@MainActor
struct PhoneHealthTools {
    private enum Kind {
        case sum, average, sleep, workout, mindful
    }

    private struct Metric {
        let type: HKSampleType
        let unit: HKUnit?
        let kind: Kind
    }

    func summary(object: [String: Any]) async throws -> PhoneToolPayload {
        let end = try PhoneToolEnvelope.date(object, "to", alias: "end", default: Date())
        let start = try PhoneToolEnvelope.date(object, "from", alias: "start",
                                                 default: Calendar.current.startOfDay(for: end))
        try validateRange(start: start, end: end)
        let defaults = ["steps", "sleepMinutes", "restingHR", "hrv", "workouts",
                        "mindfulMinutes", "bodyMass", "heartRate"]
        let requested = object["metrics"] ?? defaults
        guard let names = requested as? [String], !names.isEmpty, names.count <= 8,
              Set(names).count == names.count else {
            throw PhoneToolError.invalidArguments("metrics 必须是最多 8 个不重复指标的数组")
        }
        let store = try healthStore()
        var data: [String: Any] = [
            "from": PhoneToolEnvelope.iso8601(start),
            "to": PhoneToolEnvelope.iso8601(end),
            "metrics": names,
            "readAuthorizationIsNotObservable": true,
        ]
        var hasData = false
        for name in names {
            let metric = try metric(name)
            let points = try await series(metric: metric, start: start, end: end, store: store)
            if !points.isEmpty { hasData = true }
            switch metric.kind {
            case .sum:
                data[name] = points.isEmpty ? NSNull() : NSNumber(value: points.reduce(0) { $0 + $1.value })
            case .average:
                data[name] = points.isEmpty ? NSNull() : NSNumber(
                    value: points.reduce(0) { $0 + $1.value } / Double(points.count))
            case .sleep, .mindful:
                data[name] = points.isEmpty ? NSNull() : NSNumber(value: points.reduce(0) { $0 + $1.value } / 60)
            case .workout:
                let workouts = try await samples(metric: metric, start: start, end: end, store: store)
                    .compactMap { $0 as? HKWorkout }
                let minutes = workouts.reduce(0.0) { $0 + $1.duration / 60 }
                data["workoutCount"] = workouts.count
                data["workoutMinutes"] = minutes
                if !workouts.isEmpty { hasData = true }
            }
        }
        guard hasData else { throw PhoneToolError.noData("授权范围内没有这些健康指标的记录") }
        return PhoneToolPayload(data: data)
    }

    func query(object: [String: Any]) async throws -> PhoneToolPayload {
        let name = try PhoneToolEnvelope.text(object, "metric", limit: 40) ?? ""
        let bucket = try PhoneToolEnvelope.text(object, "bucket", required: false, limit: 10) ?? "day"
        guard bucket == "day" else { throw PhoneToolError.invalidArguments("bucket 仅支持 day") }
        let end = try PhoneToolEnvelope.date(object, "to", alias: "end", default: Date())
        let start = try PhoneToolEnvelope.date(object, "from", alias: "start",
                                                 default: end.addingTimeInterval(-7 * 86400))
        try validateRange(start: start, end: end)
        let points = try await series(metric: try metric(name), start: start, end: end,
                                      store: healthStore())
        guard !points.isEmpty else { throw PhoneToolError.noData("该时间范围内没有 \(name) 记录") }
        return PhoneToolPayload(data: [
            "metric": name,
            "bucket": bucket,
            "series": points.map { ["date": PhoneToolEnvelope.iso8601($0.date), "value": $0.value] },
        ])
    }

    private func healthStore() throws -> HKHealthStore {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw PhoneToolError.unavailable(.health, "当前设备不支持 HealthKit")
        }
        return HKHealthStore()
    }

    private func validateRange(start: Date, end: Date) throws {
        guard end > start, end.timeIntervalSince(start) <= 90 * 86400 else {
            throw PhoneToolError.invalidArguments("健康查询范围必须大于 0 且不超过 90 天")
        }
    }

    private func metric(_ name: String) throws -> Metric {
        let quantity: (HKQuantityTypeIdentifier, HKUnit, Kind)?
        switch name {
        case "steps": quantity = (.stepCount, .count(), .sum)
        case "heartRate": quantity = (.heartRate, HKUnit.count().unitDivided(by: .minute()), .average)
        case "restingHR": quantity = (.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), .average)
        case "hrv": quantity = (.heartRateVariabilitySDNN, .secondUnit(with: .milli), .average)
        case "bodyMass": quantity = (.bodyMass, .gramUnit(with: .kilo), .average)
        default: quantity = nil
        }
        if let quantity, let type = HKObjectType.quantityType(forIdentifier: quantity.0) {
            return Metric(type: type, unit: quantity.1, kind: quantity.2)
        }
        switch name {
        case "sleepMinutes", "sleep":
            guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { break }
            return Metric(type: type, unit: nil, kind: .sleep)
        case "mindfulMinutes":
            guard let type = HKObjectType.categoryType(forIdentifier: .mindfulSession) else { break }
            return Metric(type: type, unit: nil, kind: .mindful)
        case "workouts":
            return Metric(type: .workoutType(), unit: nil, kind: .workout)
        default: break
        }
        throw PhoneToolError.invalidArguments("不支持的健康指标：\(name)")
    }

    private func samples(metric: Metric, start: Date, end: Date,
                         store: HKHealthStore) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: [.strictStartDate, .strictEndDate])
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(sampleType: metric.type, predicate: predicate, limit: 50_001,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate,
                                                                        ascending: true)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
        guard result.count <= 50_000 else { throw PhoneToolError.resultTooLarge }
        return result
    }

    private func series(metric: Metric, start: Date, end: Date,
                        store: HKHealthStore) async throws -> [(date: Date, value: Double)] {
        let samples = try await samples(metric: metric, start: start, end: end, store: store)
        let calendar = Calendar.current
        var values: [Date: (total: Double, count: Int)] = [:]
        for sample in samples {
            switch metric.kind {
            case .sum, .average:
                guard let sample = sample as? HKQuantitySample, let unit = metric.unit else { continue }
                let day = calendar.startOfDay(for: sample.endDate)
                let value = sample.quantity.doubleValue(for: unit)
                values[day, default: (0, 0)].total += value
                values[day, default: (0, 0)].count += 1
            case .sleep:
                guard let sample = sample as? HKCategorySample, Self.isAsleep(sample.value) else { continue }
                addIntervals(sample: sample, start: start, end: end, values: &values)
            case .mindful:
                addIntervals(sample: sample, start: start, end: end, values: &values)
            case .workout:
                let day = calendar.startOfDay(for: sample.endDate)
                values[day, default: (0, 0)].total += 1
                values[day, default: (0, 0)].count += 1
            }
        }
        return values.keys.sorted().map { day in
            let value = values[day]!
            let average = metric.kind == .average ? value.total / Double(value.count) : value.total
            return (day, average)
        }
    }

    private func addIntervals(sample: HKSample, start: Date, end: Date,
                              values: inout [Date: (total: Double, count: Int)]) {
        var cursor = max(sample.startDate, start)
        let final = min(sample.endDate, end)
        let calendar = Calendar.current
        while cursor < final {
            let day = calendar.startOfDay(for: cursor)
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? final
            let seconds = min(next, final).timeIntervalSince(cursor)
            if seconds > 0 {
                values[day, default: (0, 0)].total += seconds
                values[day, default: (0, 0)].count += 1
            }
            cursor = next
        }
    }

    private static func isAsleep(_ value: Int) -> Bool {
        if value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue { return true }
        if #available(iOS 16.0, *) {
            return [HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue].contains(value)
        }
        return false
    }
}
