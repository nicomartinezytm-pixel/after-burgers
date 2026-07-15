import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/burger.dart';
import '../models/promo.dart';

enum PromoDeleteResult { deleted, deactivated }

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  SupabaseClient get client {
    try {
      return Supabase.instance.client;
    } catch (e) {
      throw Exception(
        'Supabase no está inicializado. Asegúrate de llamar a Supabase.initialize() en main.dart primero. Error: $e',
      );
    }
  }

  // ==================== PRODUCTOS ====================

  Future<List<Burger>> getProductos() async {
    final data = await client.from('productos').select();
    final list = data as List;
    final burgers = list
        .map((json) => Burger.fromJson(json as Map<String, dynamic>))
        .where((b) => !Promo.esFilaPromo(b.ingredientes))
        .toList();
    debugPrint('Productos cargados desde Supabase: ${burgers.length}');
    return burgers;
  }

  Future<Burger?> getProductoById(String id) async {
    try {
      final data = await client
          .from('productos')
          .select()
          .eq('id', id)
          .single();
      final burger = Burger.fromJson(data);
      if (Promo.esFilaPromo(burger.ingredientes)) return null;
      return burger;
    } catch (e) {
      return null;
    }
  }

  Future<Burger> createProducto(Burger burger) async {
    try {
      // En inserción no enviamos id: lo genera la DB (UUID/autoincrement).
      final payload = Map<String, dynamic>.from(burger.toJson())..remove('id');
      final data = await client
          .from('productos')
          .insert(payload)
          .select()
          .single();
      return Burger.fromJson(data);
    } catch (e) {
      throw Exception('Error creando producto: $e');
    }
  }

  Future<Burger> updateProducto(Burger burger) async {
    try {
      // En update NO debemos mandar el id en el payload (y soportamos uuid/int).
      final payload = Map<String, dynamic>.from(burger.toJson())..remove('id');
      final dynamic idValue = int.tryParse(burger.id) ?? burger.id;
      final data = await client
          .from('productos')
          .update(payload)
          .eq('id', idValue)
          .select()
          .single();
      return Burger.fromJson(data);
    } catch (e) {
      throw Exception('Error actualizando producto: $e');
    }
  }

  Future<void> deleteProducto(String id) async {
    try {
      final dynamic idValue = int.tryParse(id) ?? id;
      await client.from('productos').delete().eq('id', idValue);
    } catch (e) {
      throw Exception('Error eliminando producto: $e');
    }
  }

  /// Actualiza el campo `orden` de los productos para controlar el orden
  /// de aparición en el menú.
  ///
  /// Requiere que exista la columna `orden` (integer) en la tabla `productos`.
  Future<void> updateOrdenProductos(List<Burger> productosOrdenados) async {
    try {
      // Hacemos updates individuales para soportar uuid o id numérico.
      await Future.wait([
        for (int i = 0; i < productosOrdenados.length; i++)
          client
              .from('productos')
              .update({'orden': i + 1})
              .eq(
                'id',
                int.tryParse(productosOrdenados[i].id) ??
                    productosOrdenados[i].id,
              ),
      ]);
    } catch (e) {
      throw Exception('Error actualizando orden: $e');
    }
  }

  // ==================== PROMOCIONES ====================

  Future<List<Promo>> _getPromosDesdeProductos() async {
    final data = await client.from('productos').select();
    return (data as List)
        .map((json) => json as Map<String, dynamic>)
        .where((json) {
          final ing = List<String>.from(json['ingredientes'] ?? []);
          return Promo.esFilaPromo(ing);
        })
        .map(Promo.fromProductoRow)
        .toList();
  }

  Future<List<Promo>> _getPromosDesdeTablaPromociones() async {
    final data = await client.from('promociones').select();
    return (data as List)
        .map((json) => Promo.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<bool> _tablaPromocionesDisponible() async {
    try {
      await client.from('promociones').select('id').limit(1);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Promo>> getPromociones() async {
    if (await _tablaPromocionesDisponible()) {
      return _getPromosDesdeTablaPromociones();
    }
    debugPrint('Usando filas promo en tabla productos');
    return _getPromosDesdeProductos();
  }

  Future<List<Promo>> getPromocionesActivas() async {
    final todas = await getPromociones();
    final activas = todas.where((p) => p.estaVigente).toList()
      ..sort((a, b) => b.fechaInicio.compareTo(a.fechaInicio));
    debugPrint('Promociones activas: ${activas.length}');
    return activas;
  }

  Future<Promo> createPromocion(Promo promo) async {
    if (await _tablaPromocionesDisponible()) {
      final data = await client
          .from('promociones')
          .insert(promo.toJson())
          .select()
          .single();
      return Promo.fromJson(data);
    }

    final data = await client
        .from('productos')
        .insert(promo.toProductoRow(includeId: false))
        .select()
        .single();
    return Promo.fromProductoRow(data);
  }

  Future<Promo> updatePromocion(Promo promo) async {
    if (await _tablaPromocionesDisponible()) {
      final data = await client
          .from('promociones')
          .update(promo.toJson())
          .eq('id', promo.id)
          .select()
          .single();
      return Promo.fromJson(data);
    }

    // Fallback: promos guardadas como "fila promo" dentro de la tabla `productos`.
    // Dependiendo del schema, el id puede ser UUID (String) o numérico.
    final dynamic idValue = int.tryParse(promo.id) ?? promo.id;
    final data = await client
        .from('productos')
        .update(promo.toProductoRow(includeId: false))
        .eq('id', idValue)
        .select()
        .single();
    return Promo.fromProductoRow(data);
  }

  /// Borra una promo. Si falla (por ejemplo, por políticas/RLS), intenta
  /// desactivarla (activa=false) para que NO se muestre a los clientes.
  ///
  /// Retorna:
  /// - [PromoDeleteResult.deleted] si se borró.
  /// - [PromoDeleteResult.deactivated] si no se pudo borrar pero sí desactivar.
  ///
  /// Lanza excepción si no pudo hacer ninguna de las dos.
  Future<PromoDeleteResult> deletePromocion(String id) async {
    try {
      if (await _tablaPromocionesDisponible()) {
        await client.from('promociones').delete().eq('id', id);
        return PromoDeleteResult.deleted;
      }
      final dynamic idValue = int.tryParse(id) ?? id;
      await client.from('productos').delete().eq('id', idValue);
      return PromoDeleteResult.deleted;
    } catch (_) {
      await deactivatePromocion(id);
      return PromoDeleteResult.deactivated;
    }
  }

  Future<void> deactivatePromocion(String id) async {
    if (await _tablaPromocionesDisponible()) {
      await client.from('promociones').update({'activa': false}).eq('id', id);
      return;
    }

    // Fallback: promos guardadas como fila en `productos`.
    final dynamic idValue = int.tryParse(id) ?? id;
    final row = await client
        .from('productos')
        .select()
        .eq('id', idValue)
        .single();
    final promo = Promo.fromProductoRow(row).copyWith(activa: false);
    await updatePromocion(promo);
  }

  // ==================== PEDIDOS ====================

  Stream<List<Map<String, dynamic>>> getPedidosStream() {
    return client
        .from('pedidos')
        .stream(primaryKey: ['id'])
        .order('fecha', ascending: false);
  }

  Future<void> createPedido({
    required String cliente,
    required String direccion,
    required int total,
    required List<Map<String, dynamic>> items,
    required String rango,
  }) async {
    try {
      await client.from('pedidos').insert({
        'cliente': cliente,
        'direccion': direccion,
        'total': total,
        'items': items,
        'rango': rango,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (e) {
      throw Exception('Error creando pedido: $e');
    }
  }

  Future<void> deletePedido(String id) async {
    try {
      await client.from('pedidos').delete().match({'id': id});
    } catch (e) {
      throw Exception('Error eliminando pedido: $e');
    }
  }
}
