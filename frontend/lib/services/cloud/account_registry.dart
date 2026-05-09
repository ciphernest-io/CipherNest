import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'cloud_account.dart';

/// Singleton ChangeNotifier owning the list of connected cloud accounts and
/// the currently active one. Persisted to FlutterSecureStorage because it
/// holds OAuth refresh tokens.
class AccountRegistry extends ChangeNotifier {
  static final AccountRegistry _instance = AccountRegistry._internal();
  factory AccountRegistry() => _instance;
  AccountRegistry._internal();

  static const _storageKeyAccounts = 'cloud_accounts_v1';
  static const _storageKeyActive = 'active_account_id';

  final _storage = const FlutterSecureStorage();
  List<CloudAccount> _accounts = [];
  String? _activeAccountId;
  bool _loaded = false;

  List<CloudAccount> get accounts => List.unmodifiable(_accounts);
  bool get isLoaded => _loaded;
  bool get hasAnyAccount => _accounts.isNotEmpty;

  CloudAccount? get activeAccount {
    if (_activeAccountId == null) return null;
    for (final a in _accounts) {
      if (a.id == _activeAccountId) return a;
    }
    return null;
  }

  /// Load from secure storage. Called once on app startup.
  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _storageKeyAccounts);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        _accounts = list
            .map((m) => CloudAccount.fromMap(Map<String, dynamic>.from(m)))
            .toList();
      }
      _activeAccountId = await _storage.read(key: _storageKeyActive);
      // If the active id no longer matches any stored account, fall back to first.
      if (_activeAccountId != null && activeAccount == null && _accounts.isNotEmpty) {
        _activeAccountId = _accounts.first.id;
        await _persistActive();
      }
    } catch (e) {
      debugPrint('AccountRegistry load error: $e');
      _accounts = [];
      _activeAccountId = null;
    }
    _loaded = true;
    notifyListeners();
  }

  /// Add a new account. If no active account exists, this becomes active.
  Future<void> addAccount(CloudAccount account) async {
    // Replace if same id already exists (re-login refreshes tokens)
    _accounts.removeWhere((a) => a.id == account.id);
    _accounts.add(account);
    _activeAccountId ??= account.id;
    await _persistAccounts();
    await _persistActive();
    notifyListeners();
  }

  /// Switch the active account by id. No-op if id doesn't exist.
  Future<void> setActive(String accountId) async {
    if (!_accounts.any((a) => a.id == accountId)) return;
    if (_activeAccountId == accountId) return;
    _activeAccountId = accountId;
    await _persistActive();
    notifyListeners();
  }

  /// Remove an account. If it was the active one, fall back to the first
  /// remaining account, or clear active if none left.
  Future<void> removeAccount(String accountId) async {
    _accounts.removeWhere((a) => a.id == accountId);
    if (_activeAccountId == accountId) {
      _activeAccountId = _accounts.isNotEmpty ? _accounts.first.id : null;
    }
    await _persistAccounts();
    await _persistActive();
    notifyListeners();
  }

  /// Update the cached tokens for an account (called by providers after refresh).
  Future<void> updateTokens(
    String accountId, {
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) async {
    final idx = _accounts.indexWhere((a) => a.id == accountId);
    if (idx < 0) return;
    _accounts[idx] = _accounts[idx].copyWith(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt,
    );
    await _persistAccounts();
    notifyListeners();
  }

  /// Clear everything — used by master sign-out.
  Future<void> clearAll() async {
    _accounts = [];
    _activeAccountId = null;
    await _storage.delete(key: _storageKeyAccounts);
    await _storage.delete(key: _storageKeyActive);
    notifyListeners();
  }

  Future<void> _persistAccounts() async {
    final json = jsonEncode(_accounts.map((a) => a.toMap()).toList());
    await _storage.write(key: _storageKeyAccounts, value: json);
  }

  Future<void> _persistActive() async {
    if (_activeAccountId == null) {
      await _storage.delete(key: _storageKeyActive);
    } else {
      await _storage.write(key: _storageKeyActive, value: _activeAccountId!);
    }
  }
}
