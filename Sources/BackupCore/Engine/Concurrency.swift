import Foundation

/// Process `items` with bounded concurrency using a sliding-window task group.
///
/// `process` runs concurrently (up to `maxConcurrency` at once) and must only
/// touch thread-safe / read-only state. `record` is invoked **serially** in the
/// calling task as each result completes, so it's safe to mutate shared state
/// (summaries, manifests, counters) there. Results are recorded in completion
/// order, not input order.
func processConcurrently<In, Out>(
    _ items: [In],
    maxConcurrency: Int,
    isCancelled: @escaping () -> Bool = { Task.isCancelled },
    process: @escaping (Int, In) async -> Out,
    record: (Out) -> Void
) async {
    let limit = max(1, maxConcurrency)
    await withTaskGroup(of: Out.self) { group in
        var iterator = items.enumerated().makeIterator()
        var active = 0

        @discardableResult
        func addNext() -> Bool {
            guard let (index, item) = iterator.next() else { return false }
            group.addTask { await process(index, item) }
            active += 1
            return true
        }

        for _ in 0..<limit where addNext() {}

        while active > 0 {
            guard let result = await group.next() else { break }
            active -= 1
            record(result)
            if !isCancelled() { addNext() }
        }
    }
}
