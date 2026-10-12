/// Signals that a checkpoint's budget is spent and the store's controller has to be read.
///
/// Returned rather than thrown for the reason ``FuelTrap`` is: a loop's per-iteration checkpoint
/// runs on the fast path, which has to stay a straight-line handler. Only direct threading emits
/// checkpoints, so this has no token-threaded form.
enum ControlPollRequest {
    case poll

    /// The head slot of the pseudo-instruction that reads the controller, for a direct-threaded
    /// handler to return as its "next instruction".
    @inline(__always)
    var directThreadedHeadSlot: CodeSlot {
        Instruction.controlPollHeadSlot
    }
}

extension Execution {
    /// Charges the operator count of the segment beginning at this instruction against the store's
    /// polling budget.
    ///
    /// The budget is read straight from the store, because translation emits this instruction only
    /// for a direct-threaded store with an execution controller.
    @inline(__always)
    mutating func controlCheckpoint(immediate: Instruction.ControlCheckpointOperand) -> ControlPollRequest? {
        let budget = store.value.controlBudget.address
        let (remaining, underflow) = budget.pointee.subtractingReportingOverflow(immediate.raw)
        if _slowPath(underflow) {
            return .poll
        }
        budget.pointee = remaining
        return nil
    }

    /// Reads the controller, and on a live store refills the budget and continues with the
    /// checkpoint's successor.
    ///
    /// A pseudo-instruction: the translator never emits it, and `controlCheckpoint` reaches it by
    /// returning its head slot as the next instruction. By then the checkpoint has stepped `pc`
    /// past its immediate and past its successor's head slot, so that head slot sits just before
    /// `pc`, and `pc` is already where the successor expects it.
    mutating func controlPoll(sp: Sp, pc: Pc) throws -> (Pc, CodeSlot) {
        let store = self.store.value
        guard let control = store.executionControl else {
            preconditionFailure("A control checkpoint ran on a store without an execution controller")
        }
        try control.check()
        store.controlBudget.value = UInt64(control.pollingInterval)
        return (pc, pc[-1])
    }
}
