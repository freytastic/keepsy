// Rejects responses superseded by a newer request
class LatestOnly {
  int _issued = 0;

  int begin() => ++_issued;

  bool isCurrent(int token) => token == _issued;
}
