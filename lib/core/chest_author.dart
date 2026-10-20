/// Who built Chest, and how to reach them.
///
/// Kept in one place so the Settings screen and the About screen cannot drift
/// apart, and so the number is defined once rather than pasted into each widget
/// that offers WhatsApp.
class ChestAuthor {
  const ChestAuthor._();

  static const String name = 'Ayanlowo Olatunji Ayobami';

  /// Display form, with spacing, for showing to a person.
  static const String phoneDisplay = '+234 703 819 3753';

  /// Dialable form. The native side strips non-digits before building the
  /// `wa.me` link, so this only has to be unambiguous, not clean.
  static const String phoneDial = '+2347038193753';

  static const String role = 'Designer and builder';

  /// A prefilled first message, so the WhatsApp chat opens with context rather
  /// than an empty box.
  static const String whatsappGreeting = 'Hello, I use Chest and wanted to reach you.';
}
