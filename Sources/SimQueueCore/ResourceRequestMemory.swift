// SPDX-License-Identifier: MIT

extension ResourceRequest {
    /// Conservative admission arithmetic: an overflowing hint never becomes cheap.
    public func memoryCost(sims: Int, minimum: UInt64 = 0, boots: Int = 0, bootCost: UInt64 = 0) -> UInt64 {
        func product(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.multipliedReportingOverflow(by: rhs)
            return result.overflow ? .max : result.partialValue
        }
        func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? .max : result.partialValue
        }
        return sum(
            sum(max(memoryBytes, minimum), product(UInt64(max(0, sims)), memoryBytesPerSim)),
            product(UInt64(max(0, boots)), bootCost))
    }
}
