// lib/main.dart
import 'package:flutter/material.dart';

import 'screen/actualizardatos.dart';
import 'screen/consultacompra.dart';
import 'screen/consultaprecio.dart';

void main() => runApp(const MyApp());

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  int _paginaActual = 0;

  // Preserva el estado de cada pestaña (scroll/inputs)
  final PageStorageBucket _bucket = PageStorageBucket();

  // Páginas (con claves para PageStorage)
  final List<Widget> _paginas = const [
    ScreenConsulta(key: PageStorageKey<String>('consulta')),
    ScreenCompras(key: PageStorageKey<String>('compras')),
    ScreenActualizarDatos(key: PageStorageKey<String>('actualizar')),
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Madutex Consulta',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
        textTheme: const TextTheme(bodyMedium: TextStyle(color: Colors.black)),
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Blumer', style: TextStyle(fontWeight: FontWeight.bold)),
          backgroundColor: const Color.fromARGB(255, 240, 240, 240),
          elevation: 0,
        ),
        body: PageStorage(
          bucket: _bucket,
          child: IndexedStack(index: _paginaActual, children: _paginas),
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
        _buildBottomNavItem(icon: Icons.search, label: 'Existencia', isSelected: _paginaActual == 0),
        _buildBottomNavItem(icon: Icons.shopping_cart, label: 'Compras', isSelected: _paginaActual == 1),
        _buildBottomNavItem(icon: Icons.update, label: 'Actualizar', isSelected: _paginaActual == 2),
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
