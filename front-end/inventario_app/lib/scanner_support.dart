import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

Future<String?> startScannerWithFallback(
  MobileScannerController controller,
) async {
  await controller.stop();
  await controller.start(cameraDirection: CameraFacing.back);

  if (controller.value.isRunning) {
    return null;
  }

  final errorCode = controller.value.error?.errorCode;
  if (errorCode == MobileScannerErrorCode.permissionDenied) {
    return null;
  }

  await controller.start(cameraDirection: CameraFacing.front);

  if (controller.value.isRunning) {
    return 'Se activo la camara frontal porque la trasera no estuvo disponible.';
  }

  return null;
}

class ScannerErrorView extends StatelessWidget {
  const ScannerErrorView({
    super.key,
    required this.error,
    this.onRetry,
  });

  final MobileScannerException error;
  final Future<void> Function()? onRetry;

  String _buildTitle() {
    final detail = (error.errorDetails?.message ?? '').toLowerCase();

    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        return 'La app no tiene permiso para usar la camara.';
      case MobileScannerErrorCode.unsupported:
        return 'No se pudo abrir una camara disponible en este dispositivo.';
      case MobileScannerErrorCode.controllerUninitialized:
        return 'La camara todavia se esta inicializando.';
      default:
        if (detail.contains('enumerat') || detail.contains('camera')) {
          return 'No se pudieron enumerar o iniciar las camaras del dispositivo.';
        }
        return 'No se pudo iniciar la camara.';
    }
  }

  List<String> _buildTips() {
    final tips = <String>[
      'Cierra otras apps o pestanas que puedan estar usando la camara y vuelve a intentar.',
    ];

    if (kIsWeb) {
      tips.add(
          'En navegador, abre la app por HTTPS o localhost y permite la camara.');
    } else {
      tips.add(
          'Si el permiso fue denegado antes, revisalo en los ajustes del dispositivo.');
    }

    return tips;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = error.errorDetails?.message?.trim();
    final tips = _buildTips();

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.videocam_off_outlined,
                  color: Colors.white,
                  size: 42,
                ),
                const SizedBox(height: 16),
                Text(
                  _buildTitle(),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (detail != null && detail.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                for (final tip in tips) ...[
                  Text(
                    tip,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (onRetry != null) ...[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => onRetry!.call(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar camara'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
