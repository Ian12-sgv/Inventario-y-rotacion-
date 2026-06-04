import 'package:flutter/material.dart';

import 'app_session.dart';
import 'screen/consultacompra.dart';
import 'screen/consultaprecio.dart';
import 'screen/login_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  int _paginaActual = 0;
  AppSession? _session;
  PageStorageBucket _bucket = PageStorageBucket();

  List<Widget> _buildPaginas(AppSession session) => [
        ScreenConsulta(
          key: PageStorageKey('consulta-${session.username}'),
          session: session,
        ),
        ScreenCompras(
          key: PageStorageKey('compras-${session.username}'),
          session: session,
        ),
      ];

  void _handleLogin(AppSession session) {
    setState(() {
      _session = session;
      _paginaActual = 0;
      _bucket = PageStorageBucket();
    });
  }

  void _handleLogout() {
    setState(() {
      _session = null;
      _paginaActual = 0;
      _bucket = PageStorageBucket();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: Brightness.light,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Madutex Consulta',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.black),
        ),
      ),
      home: _session == null
          ? LoginScreen(onLogin: _handleLogin)
          : Scaffold(
              appBar: AppBar(
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Blumer',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      _session!.displayName,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                backgroundColor: const Color.fromARGB(255, 240, 240, 240),
                elevation: 0,
                actions: [
                  IconButton(
                    onPressed: _handleLogout,
                    tooltip: 'Cerrar sesion',
                    icon: const Icon(Icons.logout),
                  ),
                ],
              ),
              body: PageStorage(
                bucket: _bucket,
                child: IndexedStack(
                  index: _paginaActual,
                  children: _buildPaginas(_session!),
                ),
              ),
              bottomNavigationBar: _buildBottomNavigationBar(),
            ),
    );
  }

  BottomNavigationBar _buildBottomNavigationBar() {
    return BottomNavigationBar(
      currentIndex: _paginaActual,
      onTap: (i) => setState(() => _paginaActual = i),
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Colors.blueAccent,
      unselectedItemColor: Colors.grey,
      backgroundColor: Colors.white,
      elevation: 8,
      items: [
        _buildBottomNavItem(
          icon: Icons.search,
          label: 'Existencia',
          isSelected: _paginaActual == 0,
        ),
        _buildBottomNavItem(
          icon: Icons.shopping_cart,
          label: 'Compras',
          isSelected: _paginaActual == 1,
        ),
      ],
    );
  }

  BottomNavigationBarItem _buildBottomNavItem({
    required IconData icon,
    required String label,
    required bool isSelected,
  }) {
    return BottomNavigationBarItem(
      icon: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: 4,
            width: isSelected ? 20 : 0,
            decoration: BoxDecoration(
              color: isSelected ? Colors.blueAccent : Colors.transparent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Icon(icon, color: isSelected ? Colors.blueAccent : Colors.grey),
        ],
      ),
      label: label,
    );
  }
}
