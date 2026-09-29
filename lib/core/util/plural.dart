/// "1 bid", "3 bids". Pass [many] when adding "s" is wrong ("1 person").
String plural(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : (many ?? '${one}s')}';
