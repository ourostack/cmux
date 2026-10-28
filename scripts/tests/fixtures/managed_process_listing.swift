import Darwin

/// Built into the fixture module only, never the application or CLI.
public enum ManagedProcessListingFixture {
    public static func make(_ scenario: String) -> DarwinProcessListing {
        var leader = proc_bsdinfo()
        leader.pbi_pid = 12345
        leader.pbi_pgid = 12345
        leader.pbi_start_tvsec = 98765
        leader.pbi_start_tvusec = 4321
        if scenario == "pid" { leader.pbi_pid += 1 }
        if scenario == "group" { leader.pbi_pgid += 1 }
        if scenario == "seconds" { leader.pbi_start_tvsec += 1 }
        if scenario == "microseconds" { leader.pbi_start_tvusec += 1 }
        var processes = scenario == "missing" ? [] : [leader]
        if ["member", "zombie-member", "unrelated"].contains(scenario) {
            var other = leader
            other.pbi_pid += 1
            if scenario == "zombie-member" { other.pbi_status = UInt32(SZOMB) }
            if scenario == "unrelated" { other.pbi_pgid += 1 }
            processes.append(other)
        }
        return DarwinProcessListing(
            processes: processes, isComplete: scenario != "incomplete",
            missingProcessCount: scenario == "unreadable" ? 1 : 0,
            isTruncated: scenario == "truncated"
        )
    }
}
