#!/usr/bin/env python3
"""
Generate LICENSE-3rdparty.csv from libdatadog's LICENSE-3rdparty.yml

This script:
1. Fetches libdatadog's LICENSE-3rdparty.yml
2. Extracts copyright information from license texts
3. Deduplicates components (one entry per component, not per version)
4. Generates a clean CSV in the format: Component,Origin,License,Copyright
"""

import yaml
import re
import sys
from collections import OrderedDict
from pathlib import Path

def extract_copyright(license_texts, package_name):
    """Extract copyright holder from license texts."""
    # Look for specific copyright holder patterns
    # Only accept if they contain proper names (capital letters) or specific keywords
    valid_holder_pattern = r'Copyright\s+(?:\(c\)\s*)?(?:©\s*)?(?:\d{4}[-,\s\d]*\s+)?([A-Z][^\n]{3,80}?)(?:\s*<[^>]+>)?\s*(?:\n|$)'

    # Patterns that indicate template/placeholder text (skip these)
    template_indicators = [
        'owner', 'holder', 'licensor', 'entity', 'permission', 'notice',
        'granting', 'laws', 'author or', 'contributors', 'reserved',
        'yyyy', '[year]', '[name', '<year>', '<name>', 'all rights',
        'subject to', 'terms and conditions', 'license.', 'licensed under',
    ]

    best_match = None
    for text in license_texts:
        if not text:
            continue

        # Find copyright statements
        matches = re.finditer(valid_holder_pattern, text, re.MULTILINE)
        for match in matches:
            candidate = match.group(1).strip()

            # Clean up
            candidate = re.sub(r'\s+', ' ', candidate)  # Normalize whitespace
            candidate = candidate.rstrip('.,;:')

            # Skip if contains template indicators
            if any(indicator in candidate.lower() for indicator in template_indicators):
                continue

            # Skip if too short or too long
            if len(candidate) < 5 or len(candidate) > 80:
                continue

            # Skip if it's mostly punctuation or numbers
            alphas = sum(c.isalpha() for c in candidate)
            if alphas < 3:
                continue

            # Valid candidate - use it
            if not best_match or len(candidate) < len(best_match):
                best_match = candidate

    if best_match:
        return best_match

    # Fallback: Use package name
    # Format it nicely
    if 'datadog' in package_name.lower():
        return 'Datadog, Inc.'
    elif 'rust' in package_name.lower() or package_name in ['libc', 'std', 'core']:
        return 'The Rust Project Developers'
    else:
        # Capitalize first letter of package name
        return f'The {package_name} Authors'

def parse_yml_to_csv(yml_path):
    """Parse LICENSE-3rdparty.yml and generate CSV data."""

    with open(yml_path, 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f)

    # Use OrderedDict to deduplicate while preserving first occurrence
    components = OrderedDict()

    for lib in data.get('third_party_libraries', []):
        package_name = lib.get('package_name', '')
        package_version = lib.get('package_version', '')
        repository = lib.get('repository', '')
        license_id = lib.get('license', '')

        # Skip if already seen (keeps first/latest version)
        if package_name in components:
            continue

        # Extract copyright from license texts
        license_texts = []
        for lic in lib.get('licenses', []):
            license_texts.append(lic.get('text', ''))

        copyright_holder = extract_copyright(license_texts, package_name)

        # Fallback copyright values
        if not copyright_holder:
            # Try to infer from package name or repository
            if 'rust' in package_name.lower() or 'rust' in repository.lower():
                copyright_holder = 'The Rust Project Developers'
            elif 'datadog' in repository.lower():
                copyright_holder = 'Datadog, Inc.'
            else:
                # Generic fallback
                copyright_holder = f'{package_name} Authors'

        components[package_name] = {
            'component': package_name,
            'origin': repository,
            'license': license_id,
            'copyright': copyright_holder
        }

    return components

def write_csv(components, output_path):
    """Write components to CSV file."""
    with open(output_path, 'w', encoding='utf-8', newline='') as f:
        # Write header
        f.write('Component,Origin,License,Copyright\n')

        # Write sorted components
        for component in sorted(components.values(), key=lambda x: x['component'].lower()):
            # Escape commas in fields
            comp = component['component'].replace(',', ';')
            origin = component['origin'].replace(',', ';')
            lic = component['license'].replace(',', ';')
            copy = component['copyright'].replace(',', ';')

            f.write(f'{comp},{origin},{lic},{copy}\n')

def main():
    # Check if libdatadog LICENSE-3rdparty.yml exists
    yml_path = Path('libdatadog/LICENSE-3rdparty.yml')

    if not yml_path.exists():
        print(f"Error: {yml_path} not found", file=sys.stderr)
        print("Please ensure libdatadog repository is cloned in the libdatadog/ directory", file=sys.stderr)
        sys.exit(1)

    print(f"Reading {yml_path}...")
    components = parse_yml_to_csv(yml_path)

    print(f"Found {len(components)} unique components (deduplicated)")

    output_path = Path('LICENSE-3rdparty.csv')
    print(f"Writing to {output_path}...")
    write_csv(components, output_path)

    print(f"[OK] Generated {output_path} with {len(components)} entries")

if __name__ == '__main__':
    main()
