# FairBid code rules

Goal: no bloat, no unnecessary code, simple comments.

## Code

1. Write like a senior engineer who does the least work that still works.
2. Keep asking: is this necessary for the function to work? If not, leave it out.
3. Keep thinking and testing as you go.
4. Simple, short, less code. Reuse existing code and available libraries where possible.
5. Don't overcomplicate things.

## Comments

Header comment on each class or function, one or two concise lines per label:

- **What:** the component's role, as a noun phrase.
- **Input:** the data source plus the function or parameter it comes from (name the function and file, e.g. Firestore via `JobRepository.watchJobs()`).
- **Output:** the return value, rendered UI, or side effect.
- **How:** the core algorithm or logic, e.g. sorting, filtering, matching or validation.
- **Notes:** optional; edge cases, complexity, or dependencies.

Example:

```dart
/// What:   Card widget that displays a single job's summary.
/// Input:  Job list from Firestore via JobRepository.watchJobs().
/// Output: Rendered card; triggers onTap(jobId) when pressed.
/// How:    Sorts by bid price (ascending), then by created date.
/// Notes:  Rebuilds on stream updates; empty state if no jobs.
```
