import Foundation
import Testing
@testable import Brulion

struct OnboardingStepTests {
    @Test func orderMatchesTheBriefWithBielikAfterTheSpeechModel() {
        #expect(OnboardingStep.allCases == [.welcome, .permissions, .model, .bielik, .shortcut, .tryIt])
        #expect(OnboardingStep.allCases.count == 6)
    }

    @Test func rawValuesStayStableForPersistence() {
        #expect(OnboardingStep.welcome.rawValue == "welcome")
        #expect(OnboardingStep.permissions.rawValue == "permissions")
        #expect(OnboardingStep.model.rawValue == "model")
        #expect(OnboardingStep.bielik.rawValue == "bielik")
        #expect(OnboardingStep.shortcut.rawValue == "shortcut")
        #expect(OnboardingStep.tryIt.rawValue == "tryit")
        #expect(OnboardingStep.welcome.rawValue == AppSettings.defaultOnboardingStep)
    }

    @Test func nextWalksForwardAndStopsAtTheEnd() {
        #expect(OnboardingStep.welcome.next == .permissions)
        #expect(OnboardingStep.permissions.next == .model)
        #expect(OnboardingStep.model.next == .bielik)
        #expect(OnboardingStep.bielik.next == .shortcut)
        #expect(OnboardingStep.shortcut.next == .tryIt)
        #expect(OnboardingStep.tryIt.next == nil)
    }

    @Test func previousWalksBackAndStopsAtTheStart() {
        #expect(OnboardingStep.welcome.previous == nil)
        #expect(OnboardingStep.permissions.previous == .welcome)
        #expect(OnboardingStep.model.previous == .permissions)
        #expect(OnboardingStep.bielik.previous == .model)
        #expect(OnboardingStep.shortcut.previous == .bielik)
        #expect(OnboardingStep.tryIt.previous == .shortcut)
    }

    @Test func nextAndPreviousAreInverse() {
        for step in OnboardingStep.allCases {
            if let next = step.next {
                #expect(next.previous == step)
            }
            if let previous = step.previous {
                #expect(previous.next == step)
            }
        }
    }

    @Test func firstAndLastFlags() {
        #expect(OnboardingStep.welcome.isFirst)
        #expect(!OnboardingStep.welcome.isLast)
        #expect(OnboardingStep.tryIt.isLast)
        #expect(!OnboardingStep.tryIt.isFirst)
        let middle: [OnboardingStep] = [.permissions, .model, .bielik, .shortcut]
        for step in middle {
            #expect(!step.isFirst)
            #expect(!step.isLast)
        }
    }

    @Test func indexAndProgress() {
        #expect(OnboardingStep.welcome.index == 0)
        #expect(OnboardingStep.bielik.index == 3)
        #expect(OnboardingStep.tryIt.index == 5)
        #expect(OnboardingStep.welcome.progress == 1.0 / 6)
        #expect(OnboardingStep.model.progress == 0.5)
        #expect(OnboardingStep.tryIt.progress == 1)
        let progresses = OnboardingStep.allCases.map(\.progress)
        #expect(progresses == progresses.sorted())
    }

    @Test func persistedValueResolvesOrFallsBack() {
        #expect(OnboardingStep(persisted: "shortcut") == .shortcut)
        #expect(OnboardingStep(persisted: "bielik") == .bielik)
        #expect(OnboardingStep(persisted: "tryit") == .tryIt)
        #expect(OnboardingStep(persisted: "") == .welcome)
        #expect(OnboardingStep(persisted: "license") == .welcome)
        #expect(OnboardingStep(persisted: "Model") == .welcome)
    }

    @Test func titlesAreNonEmptyAndUnique() {
        let titles = OnboardingStep.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
        #expect(OnboardingStep.allCases.allSatisfy { !$0.symbol.isEmpty })
    }
}
