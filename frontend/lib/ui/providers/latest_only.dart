// Rejects responses superseded by a newer request
class LatestOnly {
  int _issued = 0;
  int _applied = 0;

  int begin() => ++_issued;

  bool isCurrent(int token) => token == _issued;

  // Accepts a response unless a newer response already applied
  bool commit(int token) {
    if (token <= _applied) return false;
    _applied = token;
    return true;
  }
}
