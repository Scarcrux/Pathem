# Registry placeholders

Defensive name reservations for "pathem" on npm and PyPI, so nobody squats the
package name. Neither is the app; both point at https://pathem.app.

Publish once, from a machine logged into your accounts:

npm (asks for browser login / OTP as needed):

    cd Packaging/registry/npm
    npm publish --access public

PyPI (needs `pipx` or `pip install build twine`):

    cd Packaging/registry/pypi
    python3 -m build
    python3 -m twine upload dist/*

Notes: npm blocks unpublish after 72 hours and PyPI discourages name reuse, so
treat both as permanent. Bump the version if a republish is ever needed.
