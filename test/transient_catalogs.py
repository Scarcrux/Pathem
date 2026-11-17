"""Shipped transient catalogs, discovered from the app's actual resources."""
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
PREFERRED=('de','ja','en','fr','es','zh-Hans')
A_LANGUAGES=('de','ja')


def shipped_languages(root=ROOT):
    resources=Path(root)/'Sources/Pathem/Resources'
    found={path.stem for path in resources.glob('*.lproj')
           if path.is_dir() and (path/'Localizable.strings').is_file()}
    if not found:raise ValueError('no shipped localization catalogs found')
    return [language for language in PREFERRED if language in found]+sorted(found-set(PREFERRED))
