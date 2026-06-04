class AppSession {
  const AppSession({
    required this.username,
    required this.password,
    required this.displayName,
  });

  final String username;
  final String password;
  final String displayName;

  Map<String, String> get authHeaders => {
        'x-user': username,
        'x-api-key': password,
        'Accept': 'application/json',
      };
}

class AllowedLogin {
  const AllowedLogin({
    required this.username,
    required this.password,
    required this.displayName,
  });

  final String username;
  final String password;
  final String displayName;

  AppSession toSession() => AppSession(
        username: username,
        password: password,
        displayName: displayName,
      );
}

const List<AllowedLogin> kAllowedLogins = [
  AllowedLogin(
    username: 'GrupoPalacio',
    password: 'PalaciosB2094',
    displayName: 'GrupoPalacio',
  ),
  AllowedLogin(
    username: 'GrupoClaudalex',
    password: 'ClaudalexD2094',
    displayName: 'GrupoClaudalex',
  ),
];

AppSession? authenticateAppSession(String username, String password) {
  final normalizedUser = username.trim().toLowerCase();
  final normalizedPassword = password.trim();

  for (final login in kAllowedLogins) {
    if (login.username.toLowerCase() == normalizedUser &&
        login.password == normalizedPassword) {
      return login.toSession();
    }
  }

  return null;
}
