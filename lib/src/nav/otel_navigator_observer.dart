// Licensed under the Apache License, Version 2.0
// Copyright 2025, Michael Bushe, All rights reserved.

import 'package:flutter/widgets.dart';
import 'package:dartastic_opentelemetry_api/dartastic_opentelemetry_api.dart';
import '../../flutterrific_opentelemetry.dart';
import './nav_util.dart';
import 'otel_route_data.dart';

/// Observer for route changes in Flutter navigation
class OTelNavigatorObserver extends NavigatorObserver {
  /// a spanId equivalent for a route
  static OTelRouteData? currentRouteData;
  static SpanId? currentRouteSpanId;

  OTelNavigatorObserver();

  void _routeChanged({
    required Route? newRoute,
    required Route? previousRoute,
    required NavigationAction newRouteChangeType,
  }) {
    OTelRouteData newOTelRouteData = newRoute == null ? OTelRouteData.empty() : _routeDataForRoute(newRoute);

    debugPrint(
      "RouteChanged ${newOTelRouteData.routeSpanId} ${newOTelRouteData.routeName}  ${newOTelRouteData.routePath}",
    );

    currentRouteSpanId = recordNavigationChange(newOTelRouteData, currentRouteData, newRouteChangeType);
    currentRouteData = newOTelRouteData;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routeChanged(newRoute: route, previousRoute: previousRoute, newRouteChangeType: NavigationAction.push);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _routeChanged(newRoute: newRoute, previousRoute: oldRoute, newRouteChangeType: NavigationAction.replace);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routeChanged(newRoute: route, previousRoute: previousRoute, newRouteChangeType: NavigationAction.pop);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routeChanged(newRoute: route, previousRoute: previousRoute, newRouteChangeType: NavigationAction.remove);
  }

  // /// Helper method for integrating with GoRouter redirect logic
  // String? handleRedirect(BuildContext context, String? fromPath, String? toPath) {
  //   if (fromPath != null && toPath != null && fromPath != toPath) {
  //     recordRedirect(fromPath, toPath, null);
  //   }
  //   return toPath;
  // }

  OTelRouteData _routeDataForRoute(Route route) {
    final settings = route.settings;

    // debugPrint("Route ${route.toString()} with settings ${settings.toString()}");

    // 1. Choose a stable, meaningful name
    String routeName;
    if (settings.name != null && settings.name!.isNotEmpty) {
      // Respect explicit names from RouteSettings
      routeName = settings.name!;
    } else {
      // Try to detect modal/dialog routes and extract descriptive names
      routeName = _detectRouteType(route);
    }

    // 2. Arguments → string
    String routeArguments;
    if (settings.arguments == null) {
      routeArguments = 'none';
    } else {
      try {
        routeArguments = settings.arguments.toString();
      } catch (_) {
        routeArguments = 'failed toString()';
      }
    }

    // 3. Stable route key (don't rely on Page)
    final routeKey = ValueKey(settings.name ?? routeName);

    // 4. Try to get a "path" (e.g., from Router/GoRouter args)
    String routePath = routeName;
    if (settings.arguments != null) {
      try {
        final args = settings.arguments;
        final uri = (args as dynamic).uri; // optional dynamic access
        routePath = uri?.toString() ?? routeName;
      } catch (_) {
        routePath = routeName;
      }
    }

    return OTelRouteData(
      routeSpanId: Context.current?.spanContext?.parentSpanId ?? OTel.spanId(),
      routeName: routeName,
      routePath: routePath,
      routeKey: routeKey.toString(),
      routeArguments: routeArguments,
    );
  }

  /// Detect route type and generate a descriptive name
  String _detectRouteType(Route route) {
    final routeTypeName = route.runtimeType.toString();

    debugPrint("Detecting route type with runtime type $routeTypeName");

    // Check for modal/dialog routes
    if (_isModalRoute(route)) {
      return _getModalName(route);
    }

    // Check for page routes
    if (route is PageRoute) {
      return 'page:$routeTypeName';
    }

    // Default fallback
    return routeTypeName;
  }

  /// Determine if this route is a modal/dialog
  bool _isModalRoute(Route route) {
    final routeType = route.runtimeType.toString();

    // Common modal/dialog route types
    final modalTypes = {
      'PopupRoute',
      'RawDialogRoute',
      'CupertinoPageRoute',
      '_ModalRoute',
      '_PopupRoute',
      'BottomSheetRoute',
      'CupertinoBarrierRoute',
      'TransitionRoute',
      'OverlayRoute',

      /// popscope?
      'PopScope',
    };

    return modalTypes.any((type) => routeType.contains(type)) || route is PopupRoute || _hasModalCharacteristics(route);
  }

  /// Extract a descriptive name for modal routes
  String _getModalName(Route route) {
    final routeType = route.runtimeType.toString();

    // Try to extract widget name from builder if available
    try {
      final builder = (route as dynamic).builder;
      if (builder != null) {
        final builderStr = builder.toString();
        // Extract class name from closure: "Closure: (BuildContext) => InstanceMirror on SomeDialog"
        final match = RegExp(r'on\s+(\w+)').firstMatch(builderStr);
        if (match != null) {
          return 'modal:${match.group(1)}';
        }
      }
    } catch (_) {
      // Ignore if builder extraction fails
    }

    // Extract from _builder if it's a PopupRoute subclass
    try {
      final builder = (route as dynamic)._builder;
      if (builder != null) {
        final builderStr = builder.toString();
        final match = RegExp(r'on\s+(\w+)').firstMatch(builderStr);
        if (match != null) {
          return 'modal:${match.group(1)}';
        }
      }
    } catch (_) {
      // Ignore if _builder extraction fails
    }

    // Fallback to type-based naming
    if (routeType.contains('BottomSheet')) {
      return 'modal:BottomSheet';
    }
    if (routeType.contains('Dialog')) {
      return 'modal:Dialog';
    }
    if (routeType.contains('Cupertino')) {
      return 'modal:CupertinoModal';
    }

    return 'modal:$routeType';
  }

  /// Check if route has modal characteristics even if type isn't explicitly modal
  bool _hasModalCharacteristics(Route route) {
    try {
      // Check if route has barrierDismissible (common for modals)
      final barrierDismissible = (route as dynamic).barrierDismissible;
      if (barrierDismissible != null) {
        return true;
      }

      // Check if route has barrierColor (modals often have a barrier)
      final barrierColor = (route as dynamic).barrierColor;
      if (barrierColor != null) {
        return true;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  /*
  Consider:

  /// Extract route parameters from GoRouter or other routers
  Map<String, dynamic> _extractRouteParameters(Route<dynamic> route) {
    final parameters = <String, dynamic>{};

    // Try to extract from arguments
    final arguments = route.settings.arguments;
    if (arguments != null) {
      if (arguments is Map<String, dynamic>) {
        // Look for common parameter keys
        for (final key in ['params', 'parameters', 'queryParams', 'queryParameters', 'pathParameters']) {
          if (arguments.containsKey(key) && arguments[key] is Map) {
            parameters.addAll(Map<String, dynamic>.from(arguments[key] as Map));
          }
        }

        // For GoRouter's state object format
        if (arguments.containsKey('uri') && arguments['uri'] is Uri) {
          final uri = arguments['uri'] as Uri;
          parameters.addAll(uri.queryParameters);
        }
      }
    }

    return parameters;
  }

  String _capitalizeFirstLetter(String input) {
    if (input.isEmpty) return input;
    return input[0].toUpperCase() + input.substring(1);
  }

  /// Updates all active routes with frame time metrics
  // void recordFrameTime(double frameTimeMs) {
  //   for (final span in _routeSpans.values) {
  //     span.setDoubleAttribute(PerformanceSemantics.frameTime.key, frameTimeMs);
  //   }
  // }

  /// Record a GoRouter redirect
  void recordRedirect(String fromPath, String toPath, Map<String, dynamic>? parameters) {
    // First check if we have an existing span for the fromPath
    final existingSpan = _goRouterPaths[fromPath];

    if (existingSpan != null) {
      // Add redirect information to the existing span
      existingSpan.setStringAttribute('redirect.to', toPath);
      existingSpan.setStringAttribute(NavigationSemantics.navigationAction.key, NavigationAction.redirect.value);
      if (parameters != null && parameters.isNotEmpty) {
        existingSpan.setStringAttribute(NavigationSemantics.routeParameters.key, parameters.toString());
      }
    } else {
      // Create a new span for the redirect
      final tracer = FlutterOTel.tracer;
      final lifecycleSpan = FlutterOTel.lifecycleObserver.getCurrentLifecycleSpan() ??
          FlutterOTel.lifecycleObserver.getAppSessionSpan();

      final attributes = <String, Object>{
        NavigationSemantics.navigationAction.key: NavigationAction.redirect.value,
        NavigationSemantics.routePath.key: fromPath,
        'redirect.to': toPath,
        RouteSemantics.lifecycleTimestamp.key: DateTime.now().millisecondsSinceEpoch,
      };

      if (parameters != null && parameters.isNotEmpty) {
        attributes[NavigationSemantics.routeParameters.key] = parameters.toString();
      }

      final span = tracer.startSpan(
        'ui.navigation.redirect',
        kind: SpanKind.client,
        attributes: sdk.OTel.attributesFromMap(attributes),
        parentSpan: lifecycleSpan,
      );

      // End the span immediately since redirect happens quickly
      span.end();
    }

    if (kDebugMode) {
      print('OTelRouteObserver: REDIRECT $fromPath → $toPath');
    }
  }
  /// Extract route path from GoRouter if available
  String _getRoutePath(Route<dynamic> route) {
    // Try to get GoRouter path from settings.name
    if (route.settings.name != null && route.settings.name!.isNotEmpty) {
      // GoRouter typically uses formats like "/home/settings" or "/product/123"
      if (route.settings.name!.startsWith('/')) {
        return route.settings.name!;
      }
    }

    // Try to extract from arguments
    final arguments = route.settings.arguments;
    if (arguments != null) {
      if (arguments is Map<String, dynamic>) {
        // Common keys for paths in different routing systems
        for (final key in ['path', 'fullPath', 'routePath', 'location', 'uri']) {
          if (arguments.containsKey(key) && arguments[key] is String) {
            return arguments[key] as String;
          }
        }
      }
    }

    // Try GoRouter specific extraction
    final goRouterPath = _extractGoRouterPath(route);
    if (goRouterPath != null) {
      return goRouterPath;
    }

    return '';
  }


  /// Extract GoRouter specific name
  String? _extractGoRouterName(Route<dynamic> route) {
    final arguments = route.settings.arguments;
    if (arguments is Map<String, dynamic>) {
      // GoRouter stores state in the arguments
      if (arguments.containsKey('name')) {
        return arguments['name'] as String?;
      }

      // For GoRouter v5+ with RouteData
      if (arguments.containsKey('routeData')) {
        final routeData = arguments['routeData'];
        if (routeData is Map && routeData.containsKey('name')) {
          return routeData['name'] as String?;
        }
      }

      // Extract name from GoRouter path
      final path = _extractGoRouterPath(route);
      if (path != null && path.isNotEmpty) {
        // Convert path to name: "/home/settings" -> "HomeSettings"
        final segments = path.split('/')
            .where((s) => s.isNotEmpty)
            .map((s) => s.contains(':') ? s.split(':')[0] : s)
            .map(_capitalizeFirstLetter)
            .toList();
        if (segments.isNotEmpty) {
          return segments.join();
        }
      }
    }
    return null;
  }

  /// Extract GoRouter specific path
  String? _extractGoRouterPath(Route<dynamic> route) {
    final arguments = route.settings.arguments;
    if (arguments is Map<String, dynamic>) {
      // GoRouter stores uri in the arguments
      if (arguments.containsKey('uri') && arguments['uri'] is Uri) {
        return (arguments['uri'] as Uri).path;
      }

      // For GoRouter with RouteData
      if (arguments.containsKey('routeData')) {
        final routeData = arguments['routeData'];
        if (routeData is Map && routeData.containsKey('path')) {
          return routeData['path'] as String?;
        }
      }

      // For older GoRouter versions
      if (arguments.containsKey('location')) {
        final location = arguments['location'] as String?;
        if (location != null) {
          final uri = Uri.tryParse(location);
          if (uri != null) {
            return uri.path;
          }
          return location;
        }
      }
    }
    return null;
  }

   */
}
