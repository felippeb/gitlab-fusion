//
//  Prepare.swift
//  gitlab-fusion
//
//  Created by Ryan Lovelett on 9/27/20.
//

import ArgumentParser
import Environment
import Foundation
import os.log
import Path
import Shout

private let log = OSLog(subsystem: subsystem, category: "prepare")

private let discussion = """
The prepare subcommand is responsible for creating the clean and isolated build
environment that the job will use.

To achieve the goal of a clean and isolated build environment this command must
be provided the path to a base VMware Guest. The prepare subcommand will then
create a snapshot on base VMware Guest (if necessary) and then make a linked
clone of the snapshot (if necessary).

The linked clone will also have a snapshot created. This snapshots will
represent the clean base state of any job. Finally, the subcommand will restore
from the snapshot and start the cloned VMware Guest.

Once the guest is started. The subcommand will wait for the guest to boot and
provide its IP address via the VMware Guest Additions. Before signaling that
the guest is working the prepare subcommand will also ensure that the SSH
server is responding and that the supplied credentials work.

https://docs.gitlab.com/runner/executors/custom.html#prepare
"""

/// The prepare stage is responsible for creating the clean and isolated build
/// environment that the job will use.
///
/// - SeeAlso: https://docs.gitlab.com/runner/executors/custom.html#prepare
struct Prepare: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "This subcommand should be called by the prepare_exec stage.",
        discussion: discussion
    )

    @OptionGroup()
    var options: StageOptions

    // MARK: - Virtual Machine runtime specific arguments

    @Argument(help: "Fully qualified path to the base VMware Fusion guest.")
    var baseVMPath: Path

    @Flag(help: "Determines if the VMware Fusion guest is started interactively.")
    var isGUI = false

    // MARK: - Secure Shell (SSH) specific arguments

    @Option(help: "User used to authenticate as over SSH to the VMware Fusion guest.")
    var sshUsername = "buildbot"

    @Option(help: "Password used to authenticate as over SSH to the VMware Fusion guest.")
    var sshPassword = "Time2Build"

    // MARK: - Validating the command-line input

    func validate() throws {
        guard options.vmrunPath.isExecutable else {
            os_log("%{public}@ is not executable.", log: log, type: .error, options.vmrunPath.string)
            throw GitlabRunnerError.systemFailure
        }

        guard options.vmImagesPath.exists, options.vmImagesPath.isWritable else {
            os_log("%{public}@ does not exist.", log: log, type: .error, options.vmImagesPath.string)
            throw GitlabRunnerError.systemFailure
        }
    }

    // MARK: - Prepare steps

    func run() throws {
        os_log("Prepare stage is starting.", log: log, type: .info)

        os_log("The base VMware Fusion guest is %{public}@", log: log, type: .debug, baseVMPath.string)
        let base = VirtualMachine(image: baseVMPath, executable: options.vmrunPath)

        /// The name of VMware Fusion guest created by the clone operation
        let clonedGuestName = "\(base.name)-runner-\(ciRunnerId)-concurrent-\(ciConcurrentProjectId)"

        // Check if the snapshot exists (creating it if necessary)
        let baseVMSnapshotName = "base-snapshot-\(clonedGuestName)"
        if !base.snapshots.contains(baseVMSnapshotName) {
            FileHandle.standardOutput
                .write(line: "Creating snapshot \"\(baseVMSnapshotName)\" in base guest \"\(base.name)\"...")
            try base.snapshot(baseVMSnapshotName)
        }

        /// The path of the VMware Fusion guest created by the clone operation
        let clonedGuestPath = options.vmImagesPath
            .join("\(clonedGuestName).vmwarevm")
            .join("\(clonedGuestName).vmx")

        // Check if the VM image exists
        let clone: VirtualMachine
        if !clonedGuestPath.exists {
            FileHandle.standardOutput
                .write(line: "Cloning from snapshot \"\(baseVMSnapshotName)\" in base guest \"\(base.name)\" to \"\(clonedGuestName)\"...")
            clone = try base.clone(to: clonedGuestPath, named: clonedGuestName, linkedTo: baseVMSnapshotName)
        } else {
            clone = VirtualMachine(image: clonedGuestPath, executable: options.vmrunPath)
        }

        /// The name of the snapshot to create on linked clone
        let cloneGuestSnapshotName = clonedGuestName

        // Check if the snapshot exists
        if clone.snapshots.contains(cloneGuestSnapshotName) {
            FileHandle.standardOutput
                .write(line: "Restoring guest \"\(clonedGuestName)\" from snapshot \"\(cloneGuestSnapshotName)\"...")
            try clone.revert(to: cloneGuestSnapshotName)
        } else {
            FileHandle.standardOutput
                .write(line: "Creating snapshot \"\(cloneGuestSnapshotName)\" in guest \"\(clonedGuestName)\"...")
            try clone.snapshot(cloneGuestSnapshotName)
        }

        FileHandle.standardOutput.write(line: "Starting guest \"\(clonedGuestName)\"...")
        try clone.start(hasGUI: isGUI)

        FileHandle.standardOutput.write(line: "Waiting for guest \"\(clonedGuestName)\" to become responsive...")
        guard let ip = clone.ip else {
            throw GitlabRunnerError.systemFailure
        }

        // Wait for ssh to become available
        for i in 1...60 {
            guard i != 60 else {
                // 'Waited 60 seconds for sshd to start, exiting...'
                throw GitlabRunnerError.systemFailure
            }

            // TODO: Encapsulate this for timeout purposes
            let ssh = try SSH(host: ip)
            try ssh.authenticate(username: sshUsername, password: sshPassword)
            let exitCode = try ssh.execute("echo -n 2>&1")

            if exitCode == 0 {
                return
            }

            sleep(60)
        }
    }
}