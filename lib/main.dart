import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config/env.dart';
import 'app.dart';
import 'services/promo_repository.dart';

void main() async {
  // Asegurar que la UI esté inicializada
  WidgetsFlutterBinding.ensureInitialized();

  // Cargar variables de entorno
  try {
    await dotenv.load(fileName: '.env');
  } catch (error) {
    debugPrint('No se pudo cargar .env: $error');
  }

  if (EnvConfig.isConfigured) {
    try {
      await Supabase.initialize(
        url: EnvConfig.supabaseUrl,
        anonKey: EnvConfig.supabaseAnonKey,
      );
    } catch (error) {
      debugPrint('No se pudo inicializar Supabase: $error');
    }
  } else {
    debugPrint('Supabase no está configurado. La app iniciará sin conexión.');
  }

  try {
    await PromoRepository().ensureInitialized();
  } catch (error) {
    debugPrint('No se pudieron inicializar promociones: $error');
  }

  // Forzar orientación portrait
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const AfterBurgersEvoApp());
}
