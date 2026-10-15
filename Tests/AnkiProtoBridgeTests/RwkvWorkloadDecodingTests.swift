//
//  RwkvWorkloadDecodingTests.swift
//  AnkiProtoBridgeTests
//
//  The bridge's `WorkloadResponse` JSON (snake_case serde fields).
//

import Testing
import Foundation
import AnkiKit
@testable import AnkiProtoBridge
@testable import AnkiBackend

@Suite struct RwkvWorkloadDecodingTests {
    @Test func rwkvSimulateWorkload_decodes_points_and_review_time() throws {
        let json = """
        {"reviewless_end_memorized":1.5,"reviewless_end_weighted_memorized":1.0,
         "points":[{"dr":30,"memorized":10.0,"weighted_memorized":9.0,"cost":120.5,"review_count":40},
                   {"dr":31,"memorized":11.0,"weighted_memorized":10.0,"cost":125.0,"review_count":42}],
         "review_time_r_bucket_count":2,"review_time_s_bucket_count":1,
         "review_time_again_seconds":[15.5,0.09375],"review_time_hard_seconds":[10.0,10.0],
         "review_time_good_seconds":[3.9117188,4.4872847],"review_time_easy_seconds":[2.5,2.5],
         "review_time_sample_counts":[3,1],
         "review_time_again_coeffs":[-2.625,36.25,0.0,0.0,0.0],"review_time_hard_coeffs":[10.0,0.0,0.0,0.0,0.0],
         "review_time_good_coeffs":[3.623936,11.511314,0.0,0.0,0.0],"review_time_easy_coeffs":[2.5,0.0,0.0,0.0,0.0],
         "review_time_grade_weights":[0.25,0.25,0.25,0.25],
         "review_time_transition_probs":[0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25,0.25],
         "review_time_transition_counts":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
         "review_time_success_grade_probs":[0.1,0.55,0.35,0.1,0.55,0.35],
         "review_time_success_grade_counts":[3,0]}
        """
        let request = RwkvWorkloadRequest(
            search: "deck:current",
            daysToSimulate: 30,
            reviewLimit: 100,
            newLimit: 2,
            newCardsIgnoreReviewLimit: false,
            maxInterval: 36500,
            reviewOrder: .day,
            suspendAfterLapseCount: nil
        )

        let result = try Request<FsrsWorkloadSimulation>.rwkvSimulateWorkload(request).decode(Data(json.utf8))

        #expect(result.cost == [30: 120.5, 31: 125])
        #expect(result.reviewCount == [30: 40, 31: 42])
        #expect(result.reviewTime.rBucketCount == 2)
        #expect(result.reviewTime.sBucketCount == 1)
        #expect(result.reviewTime.againSeconds == [15.5, 0.09375])
        #expect(result.reviewTime.goodSeconds == [3.9117188, 4.4872847])
        #expect(result.reviewTime.sampleCounts == [3, 1])
        #expect(result.reviewTime.againCoeffs == [-2.625, 36.25, 0, 0, 0])
        #expect(result.reviewTime.easyCoeffs == [2.5, 0, 0, 0, 0])
        #expect(result.reviewTime.gradeWeights == [0.25, 0.25, 0.25, 0.25])
        #expect(result.reviewTime.transitionProbs.count == 16)
        #expect(result.reviewTime.transitionCounts == Array(repeating: 0, count: 16))
        #expect(result.reviewTime.successGradeProbs == [0.1, 0.55, 0.35, 0.1, 0.55, 0.35])
        #expect(result.reviewTime.successGradeCounts == [3, 0])
    }
}
