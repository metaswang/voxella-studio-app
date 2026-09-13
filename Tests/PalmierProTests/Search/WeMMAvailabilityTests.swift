import Testing
@testable import PalmierPro

struct WeMMAvailabilityTests {
    @Test func lateInstallationRefreshCannotReactivateRemovedModel() {
        var availability = WeMMEmbeddingProvider.Availability()
        availability.update(isAvailable: true, generation: 1)
        availability.update(isAvailable: false, generation: 2)
        let applied = availability.update(isAvailable: true, generation: 1)
        #expect(!applied)
        #expect(!availability.isAvailable)
        #expect(!availability.accepts(1))
    }

    @Test func reinstallRejectsWorkFromBeforeRemoval() {
        var availability = WeMMEmbeddingProvider.Availability()
        availability.update(isAvailable: true, generation: 1)
        availability.update(isAvailable: false, generation: 2)
        availability.update(isAvailable: true, generation: 3)
        #expect(availability.accepts(3))
        #expect(!availability.accepts(1))
        let applied = availability.update(isAvailable: false, generation: 2)
        #expect(!applied)
        #expect(availability.isAvailable)
    }
}
