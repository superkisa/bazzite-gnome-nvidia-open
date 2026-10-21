# Install or reinstall the Moonshine server, preserving configuration and pairings
[group('gaming')]
[no-cd]
moonshine-install rpm="":
    bash {{ quote(source_directory() / 'install.sh') }} {{ quote(rpm) }}

# Uninstall the Moonshine server, preserving configuration and pairings
[group('gaming')]
moonshine-uninstall:
    bash {{ quote(source_directory() / 'uninstall.sh') }}

# Uninstall Moonshine and delete its configuration, certificates and pairings
[group('gaming')]
moonshine-purge:
    bash {{ quote(source_directory() / 'uninstall.sh') }} --purge
