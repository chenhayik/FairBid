/// What:   Count with a pluralised noun.
/// Input:  [count], singular [one], optional [many] when adding "s" is wrong.
/// Output: `1 bid`, `3 bids`, `2 people`.
String plural(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : (many ?? '${one}s')}';
