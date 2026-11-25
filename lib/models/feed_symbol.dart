/// Turns a ticker as people write it into the symbols the price feed knows.
///
/// People copy tickers from charting sites and brokers, which write the
/// exchange in front ("TADAWUL:2222", "NASDAQ:AAPL", "EGX:COMI"). The feed
/// writes the exchange as a suffix ("2222.SR", "COMI.CA") and none for the
/// United States. A code typed with no exchange at all is tried as it is
/// and then on the exchanges of the currency chosen for it, so "2222" with
/// SAR finds the Saudi listing.
abstract final class FeedSymbol {
  /// The feed's suffix for an exchange as it is commonly written in front
  /// of a ticker; empty for exchanges the feed lists without one.
  static const Map<String, String> _suffixOf = {
    // United States
    'NASDAQ': '', 'NYSE': '', 'AMEX': '', 'NYSEARCA': '', 'ARCA': '', 'BATS': '', 'US': '',
    // The Gulf and Egypt
    'TADAWUL': '.SR', 'SAU': '.SR', 'TASI': '.SR',
    'EGX': '.CA', 'CASE': '.CA',
    'DFM': '.AE', 'ADX': '.AD', 'QSE': '.QA', 'DSM': '.QA', 'KSE': '.KW', 'BK': '.KW',
    // Europe
    'LSE': '.L', 'LON': '.L', 'XETRA': '.DE', 'XETR': '.DE', 'ETR': '.DE', 'FRA': '.F', 'FWB': '.F',
    'EPA': '.PA', 'EURONEXT': '.PA', 'AMS': '.AS', 'EBR': '.BR', 'SWX': '.SW', 'SIX': '.SW', 'BME': '.MC', 'MIL': '.MI', 'BIT': '.MI',
    'STO': '.ST', 'OMX': '.ST', 'CPH': '.CO', 'HEL': '.HE', 'OSL': '.OL', 'BIST': '.IS', 'IST': '.IS',
    // Asia and the Pacific
    'TSE': '.T', 'TYO': '.T', 'HKEX': '.HK', 'HKG': '.HK', 'SSE': '.SS', 'SHA': '.SS', 'SZSE': '.SZ', 'SHE': '.SZ',
    'NSE': '.NS', 'BSE': '.BO', 'BOM': '.BO', 'KRX': '.KS', 'KOSDAQ': '.KQ', 'TWSE': '.TW', 'TPE': '.TW', 'SGX': '.SI', 'ASX': '.AX', 'NZX': '.NZ',
    // The Americas and Africa
    'TSX': '.TO', 'TSXV': '.V', 'BMV': '.MX', 'BVMF': '.SA', 'B3': '.SA', 'JSE': '.JO',
  };

  /// The exchanges a currency's shares mostly trade on, for a code typed
  /// without one. United States dollars have none: that is the feed's own
  /// default.
  static const Map<String, List<String>> _suffixesFor = {
    'SAR': ['.SR'],
    'EGP': ['.CA'],
    'AED': ['.AE', '.AD'],
    'QAR': ['.QA'],
    'KWD': ['.KW'],
    'GBP': ['.L'],
    'EUR': ['.DE', '.PA', '.AS', '.MI', '.MC'],
    'JPY': ['.T'],
    'HKD': ['.HK'],
    'INR': ['.NS', '.BO'],
    'CAD': ['.TO'],
    'AUD': ['.AX'],
    'CHF': ['.SW'],
    'TRY': ['.IS'],
  };

  /// The currency shares on [symbol]'s exchange trade in, read from the
  /// feed's suffix ("COMI.CA" is EGP); null when the suffix doesn't say.
  static String? currencyOf(String symbol) {
    final dot = symbol.lastIndexOf('.');
    if (dot < 0) return null;
    final suffix = symbol.substring(dot).toUpperCase();
    for (final MapEntry(key: currency, value: suffixes) in _suffixesFor.entries) {
      if (suffixes.contains(suffix)) return currency;
    }
    return null;
  }

  /// The symbols to ask the feed for, in order, for [typed] with the
  /// [currency] chosen on the screen. Never empty for a non-empty [typed];
  /// the first is the most likely.
  static List<String> candidates(String typed, {String? currency}) {
    final text = typed.trim().toUpperCase().replaceAll(RegExp(r'\s+'), '');
    if (text.isEmpty) return const [];
    final colon = text.indexOf(':');
    if (colon > 0 && colon < text.length - 1) {
      final exchange = text.substring(0, colon), code = text.substring(colon + 1);
      final suffix = _suffixOf[exchange];
      // An exchange this does not know: the code alone is the best guess,
      // then whatever the currency suggests.
      // Written both ways at once ("TADAWUL:2222.SR"): the code already
      // carries the feed's suffix.
      if (code.contains('.')) return [code];
      if (suffix != null) return ['${_code(code, suffix)}$suffix'];
      return _bare(code, currency);
    }
    return _bare(text, currency);
  }

  static List<String> _bare(String code, String? currency) {
    // Already written the feed's way, or an index.
    if (code.contains('.') || code.startsWith('^') || code.contains('=') || code.contains('-')) return [code];
    return [
      code,
      for (final suffix in _suffixesFor[currency?.toUpperCase()] ?? const <String>[]) '${_code(code, suffix)}$suffix',
    ];
  }

  /// Hong Kong codes are four digits on the feed ("5" is "0005").
  static String _code(String code, String suffix) =>
      suffix == '.HK' && RegExp(r'^\d{1,3}$').hasMatch(code) ? code.padLeft(4, '0') : code;
}
