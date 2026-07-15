import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lottie/lottie.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/constants.dart';
import '../config/env.dart';
import '../models/burger.dart';
import '../models/cart_item.dart';
import '../models/promo.dart';
import '../screens/admin_panel.dart';
import '../screens/kitchen_panel.dart';
import '../screens/promos_admin_panel.dart';
import '../services/promo_calculator.dart';
import '../services/promo_repository.dart';
import '../services/supabase_service.dart';
import '../utils/price_formatter.dart';
import '../widgets/product_image.dart';
import '../widgets/promo_banner.dart';

class MainMenuEvo extends StatefulWidget {
  const MainMenuEvo({super.key});

  @override
  State<MainMenuEvo> createState() => _MainMenuEvoState();
}

class _MainMenuEvoState extends State<MainMenuEvo>
    with TickerProviderStateMixin {
  // CONTROLADORES Y VARIABLES DE ESTADO
  late PageController _pageController;
  late AnimationController _shimmerController;
  late AnimationController _cartBadgeController;

  double _currentPage = 0.0;
  double _viewportFraction = 0.85;
  List<CartItem> carrito = [];
  int pedidosRealizados = 0;
  String favoritaName = "";
  String nombreGuardado = "";
  String direccionGuardada = "";
  Offset _cartPosition = const Offset(20, 100);
  bool ignoreTimeRestriction = false;
  bool cargandoProductos = true;
  String? _errorProductos;

  List<Burger> misBurgers = [];
  List<Promo> promosActivas = [];

  // DEFINICIÓN DE ADICIONALES DISPONIBLES
  final Map<String, int> adicionalesPrecios = {
    "Huevo": 1500,
    "Medallón extra": 3500,
    "Dip de aderezo": 500,
  };

  @override
  void initState() {
    super.initState();
    _pageController = PageController(viewportFraction: _viewportFraction)
      ..addListener(() {
        setState(() {
          _currentPage = _pageController.page!;
        });
      });

    _shimmerController = AnimationController(
      vsync: this,
      duration: AppConstants.shimmerDuration,
    )..repeat();

    _cartBadgeController = AnimationController(
      vsync: this,
      duration: AppConstants.badgeAnimationDuration,
    );

    _inicializarApp();
  }

  double _viewportFractionForWidth(double width) {
    // En desktop el PageView se vuelve gigante, así que lo achicamos.
    if (width >= 1100) return 0.36;
    if (width >= 900) return 0.42;
    if (width >= 600) return 0.70;
    return 0.85;
  }

  void _recreatePageControllerIfNeeded() {
    final desired = _viewportFractionForWidth(
      MediaQuery.of(context).size.width,
    );
    if ((desired - _viewportFraction).abs() <= 0.01) return;

    final old = _pageController;
    final current = old.hasClients ? (old.page ?? _currentPage) : _currentPage;

    _viewportFraction = desired;
    _pageController =
        PageController(
          viewportFraction: _viewportFraction,
          initialPage: current.round(),
        )..addListener(() {
          setState(() {
            _currentPage = _pageController.page!;
          });
        });

    old.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _recreatePageControllerIfNeeded();
  }

  @override
  void dispose() {
    _pageController.dispose();
    _shimmerController.dispose();
    _cartBadgeController.dispose();
    super.dispose();
  }

  Future<void> _inicializarApp() async {
    await _cargarDatosPersistentes();
    await _refreshAll();
  }

  Future<void> _refreshAll() async {
    await Future.wait([_obtenerProductosDesdeSupabase(), _cargarPromociones()]);
  }

  CartTotals get _cartTotals =>
      PromoCalculator.calculate(carrito, promosActivas);

  Future<void> _cargarPromociones() async {
    if (!EnvConfig.promosEnabled) {
      if (mounted) setState(() => promosActivas = []);
      return;
    }
    try {
      final promos = await PromoRepository().getActivas();
      if (mounted) setState(() => promosActivas = promos);
    } catch (e) {
      debugPrint('Promociones no disponibles: $e');
    }
  }

  // CARGA DE DATOS DESDE SUPABASE
  Future<void> _obtenerProductosDesdeSupabase() async {
    try {
      final listaCargada = await SupabaseService().getProductos();

      if (!mounted) return;

      if (listaCargada.isEmpty) {
        setState(() {
          misBurgers = [];
          cargandoProductos = false;
          _errorProductos =
              'La tabla "productos" está vacía o no se pudo leer desde Supabase.';
        });
        return;
      }

      final ordenada = List<Burger>.from(listaCargada)
        ..sort((a, b) {
          // Si existe "orden" lo respetamos (custom order desde admin).
          final aOrden = a.orden;
          final bOrden = b.orden;
          if (aOrden != null || bOrden != null) {
            if (aOrden == null) return 1;
            if (bOrden == null) return -1;
            final cmpOrden = aOrden.compareTo(bOrden);
            if (cmpOrden != 0) return cmpOrden;
          }

          final aEsOferta = _esOferta(a);
          final bEsOferta = _esOferta(b);
          if (aEsOferta != bEsOferta) {
            return aEsOferta ? -1 : 1; // ofertas primero
          }

          final ac = a.createdAt;
          final bc = b.createdAt;
          if (ac != null && bc != null) {
            final cmp = bc.compareTo(ac); // más nuevos primero
            if (cmp != 0) return cmp;
          }

          return a.nombre.toLowerCase().compareTo(b.nombre.toLowerCase());
        });

      setState(() {
        misBurgers = ordenada;
        cargandoProductos = false;
        _errorProductos = null;
        _actualizarFavorita();
      });
    } catch (e) {
      debugPrint('Error cargando productos: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No pudimos cargar el menu. Intenta nuevamente.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 5),
        ),
      );
      setState(() {
        misBurgers = [];
        cargandoProductos = false;
        _errorProductos =
            'No pudimos cargar el menu. Revisa tu conexion e intenta nuevamente.';
      });
    }
  }

  bool _esOferta(Burger b) {
    final cat = b.categoria.toLowerCase();
    final name = b.nombre.toLowerCase();
    return cat == 'combos' ||
        name.contains('oferta') ||
        name.contains('promo') ||
        name.contains('2x1') ||
        name.contains('2 x 1');
  }

  Future<void> _cargarDatosPersistentes() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      pedidosRealizados = prefs.getInt('pedidos_count') ?? 0;
      nombreGuardado = prefs.getString('cliente_nombre') ?? "";
      direccionGuardada = prefs.getString('cliente_direccion') ?? "";
    });
  }

  void _actualizarFavorita() {
    if (misBurgers.isEmpty) return;
    SharedPreferences.getInstance().then((prefs) {
      String maxKey = "";
      int maxVal = 0;
      for (var b in misBurgers) {
        int count = prefs.getInt('count_${b.nombre}') ?? 0;
        if (count > maxVal) {
          maxVal = count;
          maxKey = b.nombre;
        }
      }
      if (maxVal > 2) {
        setState(() {
          favoritaName = maxKey;
        });
      }
    });
  }

  // LÓGICA DE HORARIOS
  bool get estaAbierto {
    if (ignoreTimeRestriction) return true;
    final now = DateTime.now();
    final openingHour = EnvConfig.openingHour;
    final closingHour = EnvConfig.closingHour;

    if (openingHour < closingHour) {
      // Ej: 9 a 17 (horario diurno)
      return now.hour >= openingHour && now.hour < closingHour;
    } else {
      // Ej: 21 a 3 (horario nocturno cruzado)
      return now.hour >= openingHour || now.hour < closingHour;
    }
  }

  String get rangoActual => AppConstants.getRango(pedidosRealizados);

  // ACCESO ADMIN
  void _mostrarLoginAdmin() {
    final passController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppConstants.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppConstants.primaryColor),
        ),
        title: Text(
          "ACCESO RESTRINGIDO",
          style: GoogleFonts.bebasNeue(color: AppConstants.primaryColor),
        ),
        content: TextField(
          controller: passController,
          obscureText: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: "Contraseña",
            labelStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCELAR"),
          ),
          ElevatedButton(
            onPressed: () {
              if (passController.text == EnvConfig.adminPassword) {
                Navigator.pop(context);
                _mostrarMenuAdmin();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Contraseña incorrecta"),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            child: const Text("ENTRAR"),
          ),
        ],
      ),
    );
  }

  void _mostrarMenuAdmin() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppConstants.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: AppConstants.primaryColor),
        ),
        title: Text(
          "PANEL ADMIN",
          style: GoogleFonts.bebasNeue(
            color: AppConstants.primaryColor,
            fontSize: 20,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.restaurant,
                color: AppConstants.primaryColor,
              ),
              title: const Text(
                "COCINA - PEDIDOS",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const KitchenPanel()),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.edit_note,
                color: AppConstants.primaryColor,
              ),
              title: const Text(
                "ADMINISTRAR PRODUCTOS",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const AdminPanel()),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.local_offer,
                color: AppConstants.primaryColor,
              ),
              title: const Text(
                "PROMOCIONES",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PromosAdminPanel(),
                  ),
                ).then((_) => _cargarPromociones());
              },
            ),
          ],
        ),
      ),
    );
  }

  // CARRITO Y PERSISTENCIA
  void _agregarAlCarrito(
    Burger burger, {
    int personas = 1,
    List<String> quitados = const [],
    List<String> adicionales = const [],
    int extraPrecio = 0,
  }) {
    if (!estaAbierto) {
      _showClosedNotice();
      return;
    }

    HapticFeedback.mediumImpact();
    _cartBadgeController.forward(from: 0.0);

    setState(() {
      carrito.add(
        CartItem(
          burger: burger,
          personas: personas,
          ingredientesQuitados: List.from(quitados),
          adicionalesSumados: List.from(adicionales),
          extraPrecio: extraPrecio,
        ),
      );
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("${burger.nombre} añadida al carrito"),
        backgroundColor: AppConstants.primaryColor.withOpacity(0.9),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showClosedNotice() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(AppConstants.closedMessage),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _mostrarFormularioDatos() {
    final nameController = TextEditingController(text: nombreGuardado);
    final addressController = TextEditingController(text: direccionGuardada);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: AppConstants.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Colors.white10),
        ),
        title: Text(
          "DATOS DE ENTREGA",
          style: GoogleFonts.bebasNeue(
            color: AppConstants.primaryColor,
            fontSize: 24,
            letterSpacing: 2,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: "Tu Nombre",
                labelStyle: TextStyle(color: Colors.white38),
              ),
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: addressController,
              decoration: const InputDecoration(
                labelText: "Dirección Exacta",
                labelStyle: TextStyle(color: Colors.white38),
              ),
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              "CANCELAR",
              style: TextStyle(color: Colors.white24),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppConstants.primaryColor,
            ),
            onPressed: () async {
              if (nameController.text.trim().isNotEmpty &&
                  addressController.text.trim().isNotEmpty) {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(
                  'cliente_nombre',
                  nameController.text.trim(),
                );
                await prefs.setString(
                  'cliente_direccion',
                  addressController.text.trim(),
                );

                setState(() {
                  nombreGuardado = nameController.text.trim();
                  direccionGuardada = addressController.text.trim();
                });

                Navigator.pop(context);
                _procesarPedidoConAnimacion();
              }
            },
            child: const Text(
              "CONFIRMAR",
              style: TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _guardarEnSupabase() async {
    try {
      final supabaseService = SupabaseService();
      final totals = _cartTotals;

      await supabaseService.createPedido(
        cliente: nombreGuardado,
        direccion: direccionGuardada,
        total: totals.total,
        items: carrito
            .map(
              (item) => {
                'nombre': item.burger.nombre,
                'cantidad': item.personas,
                'sin': item.ingredientesQuitados,
                'adicionales': item.adicionalesSumados,
              },
            )
            .toList(),
        rango: rangoActual,
      );
    } catch (e) {
      debugPrint("Error guardando en Supabase: $e");
    }
  }

  void _procesarPedidoConAnimacion() {
    if (carrito.isEmpty) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        Future.delayed(AppConstants.orderAnimationDuration, () async {
          if (mounted) {
            await _guardarEnSupabase();
            Navigator.pop(context);
            _enviarWhatsApp();
          }
        });

        return Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Lottie.asset(
                'assets/lottie/Ready For Delivery.json',
                width: 250,
                repeat: true,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.delivery_dining,
                  size: 100,
                  color: AppConstants.primaryColor,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                "¡MARCHANDO!",
                style: GoogleFonts.bebasNeue(
                  color: AppConstants.primaryColor,
                  fontSize: 28,
                  letterSpacing: 4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _enviarWhatsApp() async {
    final prefs = await SharedPreferences.getInstance();

    int nuevosPedidos = pedidosRealizados + 1;
    await prefs.setInt('pedidos_count', nuevosPedidos);

    for (var item in carrito) {
      int countActual = prefs.getInt('count_${item.burger.nombre}') ?? 0;
      await prefs.setInt('count_${item.burger.nombre}', countActual + 1);
    }

    final numero = EnvConfig.whatsappNumber;
    String mensaje = "🍔 *NUEVO PEDIDO: AFTER BURGERS*\n";
    mensaje += "--------------------------\n";
    mensaje += "👤 *CLIENTE:* $nombreGuardado\n";
    mensaje += "📍 *ENTREGA:* $direccionGuardada\n";
    mensaje += "🎖️ *NIVEL:* $rangoActual\n";
    mensaje +=
        "⏰ *HORA:* ${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')} hs\n";
    if (EnvConfig.promosEnabled && promosActivas.isNotEmpty) {
      mensaje += "🎁 *PROMOS VIGENTES:*\n";
      for (final promo in promosActivas) {
        mensaje += "• ${promo.titulo}: ${promo.descripcion}\n";
      }
    }
    mensaje += "--------------------------\n";

    final totals = _cartTotals;

    for (var item in carrito) {
      mensaje +=
          "• *${item.burger.nombre}* (${PriceFormatter.formatFromString(item.burger.precio)})\n";

      if (item.personas > 1) {
        mensaje += "  ↳ Cantidad: ${item.personas}\n";
      }

      if (item.ingredientesQuitados.isNotEmpty) {
        mensaje += "  ↳ _SIN: ${item.ingredientesQuitados.join(', ')}_\n";
      }

      if (item.adicionalesSumados.isNotEmpty) {
        mensaje += "  ↳ _EXTRA: ${item.adicionalesSumados.join(', ')}_\n";
      }

      mensaje += "  ↳ ${PriceFormatter.format(item.totalPrice)}\n";
    }

    if (totals.discount > 0) {
      mensaje += "\n📉 *DESCUENTOS:*\n";
      for (final line in totals.discountLines) {
        mensaje += "• $line\n";
      }
    }
    if (totals.promoNotes.isNotEmpty) {
      mensaje += "\n🎁 *BENEFICIOS:*\n";
      for (final note in totals.promoNotes) {
        mensaje += "• $note\n";
      }
    }

    mensaje += "\n💰 *TOTAL A PAGAR: ${PriceFormatter.format(totals.total)}*";

    final Uri whatsappUri = Uri.parse(
      "whatsapp://send?phone=$numero&text=${Uri.encodeComponent(mensaje)}",
    );
    final Uri webUri = Uri.parse(
      "https://wa.me/$numero?text=${Uri.encodeComponent(mensaje)}",
    );

    try {
      if (await canLaunchUrl(whatsappUri)) {
        await launchUrl(whatsappUri);
      } else {
        await launchUrl(webUri, mode: LaunchMode.externalApplication);
      }

      setState(() {
        carrito.clear();
        pedidosRealizados = nuevosPedidos;
        _actualizarFavorita();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No se pudo abrir WhatsApp")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const Color accent = AppConstants.primaryColor;

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                _buildHeader(accent),
                if (!estaAbierto) _buildClosedBanner(),
                if (promosActivas.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  PromoBannerCarousel(promos: promosActivas),
                  const SizedBox(height: 8),
                ],
                Expanded(
                  child: RefreshIndicator(
                    color: accent,
                    backgroundColor: AppConstants.cardColor,
                    onRefresh: _refreshAll,
                    child: _buildMenuContent(accent),
                  ),
                ),
              ],
            ),
          ),

          if (carrito.isNotEmpty)
            Positioned(
              left: _cartPosition.dx,
              bottom: _cartPosition.dy,
              child: Draggable(
                feedback: Material(
                  color: Colors.transparent,
                  child: _buildFAB(accent),
                ),
                childWhenDragging: Container(),
                onDragEnd: (details) {
                  setState(() {
                    double newY =
                        MediaQuery.of(context).size.height -
                        details.offset.dy -
                        60;
                    _cartPosition = Offset(
                      details.offset.dx,
                      newY.clamp(
                        20.0,
                        MediaQuery.of(context).size.height - 150,
                      ),
                    );
                  });
                },
                child: _buildFAB(accent),
              ),
            ),
        ],
      ),
    );
  }

  // WIDGETS DE SOPORTE UI
  Widget _buildClosedBanner() {
    return Container(
      width: double.infinity,
      color: Colors.redAccent.withOpacity(0.1),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: const Center(
        child: Text(
          "LOCAL CERRADO - ABRIMOS DE 21:00 A 03:00",
          style: TextStyle(
            color: Colors.redAccent,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }

  Widget _buildFAB(Color accent) {
    return ScaleTransition(
      scale: Tween(begin: 1.0, end: 1.1).animate(
        CurvedAnimation(parent: _cartBadgeController, curve: Curves.elasticOut),
      ),
      child: FloatingActionButton.extended(
        onPressed: () => _mostrarCarrito(accent),
        backgroundColor: accent,
        elevation: 10,
        label: Text(
          "${carrito.length}",
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
        icon: const Icon(Icons.shopping_bag_outlined, color: Colors.black),
      ),
    );
  }

  Widget _buildHeader(Color accent) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onLongPress: _mostrarLoginAdmin,
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "AFTER",
                  style: GoogleFonts.bebasNeue(
                    fontSize: 14,
                    letterSpacing: 5,
                    color: Colors.white24,
                  ),
                ),
                Text(
                  "BURGERS",
                  style: GoogleFonts.bebasNeue(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
          GestureDetector(
            onLongPress: () {
              setState(() => ignoreTimeRestriction = !ignoreTimeRestriction);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    "Restricción horaria: ${ignoreTimeRestriction ? 'OFF' : 'ON'}",
                  ),
                ),
              );
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                rangoActual,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _mostrarCarrito(Color accent) {
    final totals = _cartTotals;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppConstants.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Container(
            padding: const EdgeInsets.all(30),
            height: MediaQuery.of(context).size.height * 0.75,
            child: Column(
              children: [
                Text(
                  "RESUMEN DE PEDIDO",
                  style: GoogleFonts.bebasNeue(fontSize: 24, letterSpacing: 2),
                ),
                const Divider(color: Colors.white10, height: 40),
                Expanded(
                  child: ListView.builder(
                    itemCount: carrito.length,
                    itemBuilder: (context, i) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        carrito[i].burger.nombre,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        carrito[i].resumen,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            PriceFormatter.format(carrito[i].totalPrice),
                            style: TextStyle(
                              color: accent,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.redAccent,
                              size: 18,
                            ),
                            onPressed: () {
                              setModalState(() => carrito.removeAt(i));
                              setState(() {});
                              if (carrito.isEmpty) Navigator.pop(context);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(color: Colors.white10),
                if (totals.discount > 0) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'SUBTOTAL',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      Text(
                        PriceFormatter.format(totals.subtotal),
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...totals.discountLines.map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        line,
                        style: const TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  if (totals.promoNotes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ...totals.promoNotes.map(
                      (note) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          note,
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                ],
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        totals.discount > 0
                            ? 'TOTAL CON PROMOS'
                            : 'TOTAL ESTIMADO',
                        style: const TextStyle(color: Colors.white54),
                      ),
                      Text(
                        PriceFormatter.format(totals.total),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    minimumSize: const Size(double.infinity, 65),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  onPressed: () {
                    if (!estaAbierto) {
                      Navigator.pop(context);
                      _showClosedNotice();
                    } else {
                      Navigator.pop(context);
                      _mostrarFormularioDatos();
                    }
                  },
                  child: const Text(
                    "FINALIZAR PEDIDO",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBurgerCard(Burger burger, Color accent) {
    bool isFavorita = burger.nombre == favoritaName;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: AppConstants.cardColor,
            borderRadius: BorderRadius.circular(AppConstants.cardBorderRadius),
            border: Border.all(
              color: isFavorita
                  ? accent.withOpacity(0.3)
                  : Colors.white.withOpacity(0.05),
              width: isFavorita ? 2 : 1,
            ),
          ),
          child: Stack(
            children: [
              Column(
                children: [
                  // La altura disponible cambia cuando hay promos arriba.
                  // Para que las fotos no se "rompan" en pantallas chicas, fijamos
                  // un ratio estable para la imagen y dejamos el resto scrolleable.
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: AspectRatio(
                        aspectRatio: 4 / 3,
                        child: ProductImage(
                          imagePath: burger.imagePath,
                          accentColor: accent,
                          width: double.infinity,
                          height: double.infinity,
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(30, 0, 30, 30),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  burger.nombre,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                PriceFormatter.formatFromString(burger.precio),
                                style: TextStyle(
                                  color: accent,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          const Text(
                            AppConstants.includesFries,
                            style: TextStyle(
                              color: Colors.amber,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            burger.descripcion,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 25),
                          _buildMainButton(burger, accent),
                          const SizedBox(height: 12),
                          _buildExtraButtons(burger, accent),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (isFavorita)
                Positioned(
                  top: 30,
                  right: 30,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      "TU FAVORITA ⭐",
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuContent(Color accent) {
    if (cargandoProductos) {
      return Center(child: CircularProgressIndicator(color: accent));
    }
    if (misBurgers.isEmpty) {
      return _buildEmptyMenu(accent);
    }
    return PageView.builder(
      controller: _pageController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: misBurgers.length,
      itemBuilder: (context, index) {
        final delta = (_currentPage - index).abs();
        return Transform.scale(
          scale: (1 - (delta * 0.12)).clamp(0.8, 1.0),
          child: Opacity(
            opacity: (1 - (delta * 0.5)).clamp(0.0, 1.0),
            child: _buildBurgerCard(misBurgers[index], accent),
          ),
        );
      },
    );
  }

  Widget _buildEmptyMenu(Color accent) {
    final configHint = EnvConfig.configurationWarning;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off, size: 64, color: accent.withOpacity(0.5)),
            const SizedBox(height: 16),
            Text(
              _errorProductos ?? 'No se encontraron hamburguesas',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            if (configHint != null) ...[
              const SizedBox(height: 12),
              Text(
                configHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.amber, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                setState(() => cargandoProductos = true);
                _obtenerProductosDesdeSupabase();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: Colors.black,
              ),
              child: const Text('REINTENTAR'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainButton(Burger burger, Color accent) {
    bool closed = !estaAbierto;
    return GestureDetector(
      onTap: () => _agregarAlCarrito(burger),
      child: AnimatedBuilder(
        animation: _shimmerController,
        builder: (context, child) => Container(
          height: 60,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(
              AppConstants.buttonBorderRadius,
            ),
            color: closed ? Colors.white10 : null,
            gradient: closed
                ? null
                : LinearGradient(
                    colors: [accent, Colors.white.withOpacity(0.7), accent],
                    stops: [
                      (_shimmerController.value - 0.2).clamp(0.0, 1.0),
                      _shimmerController.value,
                      (_shimmerController.value + 0.2).clamp(0.0, 1.0),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
          ),
          child: Center(
            child: Text(
              closed ? "PEDIR A PARTIR DE LAS 21:00" : "AGREGAR AL CARRITO",
              style: TextStyle(
                color: closed ? Colors.white24 : Colors.black,
                fontWeight: FontWeight.w900,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExtraButtons(Burger burger, Color accent) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => _showGroupOrder(burger, accent),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: accent.withOpacity(0.2)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(15),
              ),
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            child: const Text(
              "PARA VARIOS",
              style: TextStyle(
                fontSize: 10,
                color: Colors.white70,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton(
          onPressed: () => _showCustomization(burger, accent),
          icon: Icon(Icons.tune, color: accent, size: 28),
        ),
      ],
    );
  }

  void _showGroupOrder(Burger burger, Color accent) {
    if (!estaAbierto) {
      _showClosedNotice();
      return;
    }
    int cantidad = 2;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppConstants.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "¿CUÁNTAS PERSONAS COMEN?",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 30),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _counterBtn(
                      Icons.remove,
                      () => setModalState(() {
                        if (cantidad > 1) cantidad--;
                      }),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 30),
                      child: Text(
                        "$cantidad",
                        style: TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                          color: accent,
                        ),
                      ),
                    ),
                    _counterBtn(
                      Icons.add,
                      () => setModalState(() {
                        cantidad++;
                      }),
                    ),
                  ],
                ),
                const SizedBox(height: 40),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    minimumSize: const Size(double.infinity, 60),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _agregarAlCarrito(burger, personas: cantidad);
                  },
                  child: const Text(
                    "CONFIRMAR GRUPO",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _counterBtn(IconData icon, VoidCallback tap) => GestureDetector(
    onTap: tap,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: Colors.white),
    ),
  );

  void _showCustomization(Burger burger, Color accent) {
    if (!estaAbierto) {
      _showClosedNotice();
      return;
    }

    List<String> quitadosLocal = [];
    List<String> adicionalesLocal = [];
    int extraAcumulado = 0;

    final opciones = burger.ingredientes
        .where((ing) => ing.toLowerCase() != "carne")
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppConstants.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setMState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "PERSONALIZAR",
                  style: GoogleFonts.bebasNeue(fontSize: 22),
                ),
                const Text(
                  "Quitar ingredientes:",
                  style: TextStyle(color: Colors.white24, fontSize: 11),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        ...opciones.map(
                          (ing) => CheckboxListTile(
                            title: Text(
                              ing,
                              style: const TextStyle(fontSize: 14),
                            ),
                            value: !quitadosLocal.contains(ing),
                            activeColor: accent,
                            onChanged: (val) => setMState(() {
                              val!
                                  ? quitadosLocal.remove(ing)
                                  : quitadosLocal.add(ing);
                            }),
                          ),
                        ),
                        const Divider(color: Colors.white10),
                        const Text(
                          "AGREGAR EXTRAS:",
                          style: TextStyle(
                            color: Colors.amber,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        ...adicionalesPrecios.entries.map(
                          (entry) => CheckboxListTile(
                            title: Text(
                              "${entry.key} (+\$${entry.value})",
                              style: const TextStyle(fontSize: 14),
                            ),
                            value: adicionalesLocal.contains(entry.key),
                            activeColor: Colors.amber,
                            onChanged: (val) => setMState(() {
                              if (val!) {
                                adicionalesLocal.add(entry.key);
                                extraAcumulado += entry.value;
                              } else {
                                adicionalesLocal.remove(entry.key);
                                extraAcumulado -= entry.value;
                              }
                            }),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    minimumSize: const Size(double.infinity, 55),
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                    _agregarAlCarrito(
                      burger,
                      quitados: quitadosLocal,
                      adicionales: adicionalesLocal,
                      extraPrecio: extraAcumulado,
                    );
                  },
                  child: const Text(
                    "GUARDAR Y AÑADIR",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
