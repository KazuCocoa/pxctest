//
//  RunTestsWorker.swift
//  pxctest
//
//  Created by Johannes Plunien on 29/12/2016.
//  Copyright © 2016 Johannes Plunien. All rights reserved.
//

import FBSimulatorControl
import Foundation

final class RunTestsWorker {

    let applications: [FBApplicationDescriptor]
    let name: String
    let simulator: FBSimulator
    let testLaunchConfiguration: FBTestLaunchConfiguration

    var configuration: FBSimulatorConfiguration {
        return simulator.configuration!
    }

    private(set) var errors: [RunTestsError] = []

    init(name: String, applications: [FBApplicationDescriptor], simulator: FBSimulator, testLaunchConfiguration: FBTestLaunchConfiguration) {
        self.name = name
        self.applications = applications
        self.simulator = simulator
        self.testLaunchConfiguration = testLaunchConfiguration
    }

    func abortTestRun() throws {
        for application in applications {
            try simulator.killApplication(withBundleID: application.bundleID)
        }
    }

    func extractDiagnostics(fileManager: RunTestsFileManager) throws {
        for application in applications {
            guard let diagnostics = simulator.simulatorDiagnostics.launchedProcessLogs().first(where: { $0.0.processName == application.name })?.value else { continue }
            let destinationPath = fileManager.urlFor(worker: self).path
            try diagnostics.writeOut(toDirectory: destinationPath)
        }
        for error in errors {
            for crash in error.crashes {
                let destinationPath = fileManager.urlFor(worker: self).path
                try crash.writeOut(toDirectory: destinationPath)
            }
        }
    }

    func startTests(context: RunTestsContext, reporters: RunTestsReporters) throws {
        let testsToRun = context.testsToRun[name] ?? Set<String>()
        let testEnvironment = Environment.injectPrefixedVariables(from: context.environment, into: testLaunchConfiguration.testEnvironment)
        let testLaunchConfigurartion = self.testLaunchConfiguration
            .withTestsToRun(self.testLaunchConfiguration.testsToRun.union(testsToRun))
            .withTestEnvironment(testEnvironment)

        let reporter = try reporters.addReporter(for: simulator, name: name)

        try simulator.interact.startTest(with: testLaunchConfigurartion, reporter: reporter).perform()
    }

    func waitForTestResult(timeout: TimeInterval) {
        let testManagerResults = simulator.resourceSink.testManagers.flatMap { $0.waitUntilTestingHasFinished(withTimeout: timeout) }
        if testManagerResults.reduce(true, { $0 && $1.didEndSuccessfully }) {
            return
        }
        errors.append(
            RunTestsError(
                simulator: simulator,
                target: name,
                errors: testManagerResults.flatMap { $0.error },
                crashes: testManagerResults.flatMap { $0.crashDiagnostic }
            )
        )
    }

    // MARK: -

    class func allocate(pool: FBSimulatorPool, context: AllocationContext, targets: [FBXCTestRunTarget]) throws -> [RunTestsWorker] {
        var workers: [RunTestsWorker] = []

        for target in targets {
            if context.testsToRun.count > 0 && context.testsToRun[target.name] == nil {
                continue
            }
            for simulatorConfiguration in context.simulatorConfigurations {
                try context.fileManager.createDirectoryFor(simulatorConfiguration: simulatorConfiguration, target: target.name)
                let simulator = try pool.allocateSimulator(with: simulatorConfiguration, options: context.simulatorOptions.allocationOptions)
                let worker = RunTestsWorker(
                    name: target.name,
                    applications: target.applications,
                    simulator: simulator,
                    testLaunchConfiguration: target.testLaunchConfiguration
                )
                workers.append(worker)
            }
        }
        return workers
    }


}

extension Sequence where Iterator.Element == RunTestsWorker {

    func abortTestRun() throws {
        for worker in self {
            try worker.abortTestRun()
        }
    }

    func boot(context: BootContext) throws {
        for worker in self {
            guard worker.simulator.state != .booted else { continue }
            try worker.simulator.interact.boot(context: context).perform()
        }
    }

    func installApplications() throws {
        for worker in self {
            try worker.simulator.reinstall(applications: worker.applications)
        }
    }

    func loadDefaults(context: DefaultsContext) throws {
        for worker in self {
            try worker.simulator.interact.loadDefaults(context: context).perform()
        }
    }

    func overrideWatchDogTimer() throws {
        for worker in self {
            let applications = worker.applications.map { $0.bundleID }
            try worker.simulator.interact.overrideWatchDogTimer(forApplications: applications, withTimeout: 60.0).perform()
        }
    }

    func startTests(context: RunTestsContext, reporters: RunTestsReporters) throws {
        for worker in self {
            try worker.startTests(context: context, reporters: reporters)
        }
    }

    func waitForTestResult(context: TestResultContext) throws -> [RunTestsError] {
        for worker in self {
            worker.waitForTestResult(timeout: context.timeout)
        }

        for worker in self {
            try worker.extractDiagnostics(fileManager: context.fileManager)
        }

        return flatMap { $0.errors }
    }

}
