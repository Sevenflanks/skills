import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = process.cwd();
const errors = [];

function fail(message) {
  errors.push(message);
}

function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (error) {
    fail(`${path.relative(root, filePath)} is not valid JSON: ${error.message}`);
    return null;
  }
}

function parseFrontmatter(content, filePath) {
  if (!content.startsWith('---\n')) {
    fail(`${path.relative(root, filePath)} is missing YAML frontmatter`);
    return new Map();
  }

  const end = content.indexOf('\n---', 4);
  if (end === -1) {
    fail(`${path.relative(root, filePath)} frontmatter is not closed`);
    return new Map();
  }

  const entries = new Map();
  const frontmatter = content.slice(4, end).split(/\r?\n/);
  let currentObject = null;

  for (const line of frontmatter) {
    const nestedMatch = line.match(/^\s{2}([A-Za-z0-9_-]+):\s*(.*)$/);
    if (nestedMatch && currentObject) {
      entries.set(`${currentObject}.${nestedMatch[1]}`, nestedMatch[2].trim());
      continue;
    }

    const match = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (match) {
      entries.set(match[1], match[2].trim());
      currentObject = match[2].trim() === '' ? match[1] : null;
    }
  }

  return entries;
}

const catalogPath = path.join(root, 'skills.json');
const marketplacePath = path.join(root, '.claude-plugin', 'marketplace.json');
const marketplace = fs.existsSync(marketplacePath) ? readJson(marketplacePath) : null;

if (!fs.existsSync(marketplacePath)) {
  fail('.claude-plugin/marketplace.json is missing');
}

if (!fs.existsSync(catalogPath)) {
  fail('skills.json is missing');
} else {
  const catalog = readJson(catalogPath);

  if (catalog) {
    if (catalog.schema_version !== 1) {
      fail('skills.json schema_version must be 1');
    }

    if (!Array.isArray(catalog.skills)) {
      fail('skills.json must contain a skills array');
    } else {
      const names = new Set();
      const paths = new Set();

      for (const [index, skill] of catalog.skills.entries()) {
        const prefix = `skills.json skills[${index}]`;
        if (!skill || typeof skill !== 'object') {
          fail(`${prefix} must be an object`);
          continue;
        }

        if (!skill.name || typeof skill.name !== 'string') {
          fail(`${prefix}.name is required`);
          continue;
        }

        if (!skill.path || typeof skill.path !== 'string') {
          fail(`${prefix}.path is required`);
          continue;
        }

        if (names.has(skill.name)) {
          fail(`duplicate skill name: ${skill.name}`);
        }
        names.add(skill.name);

        if (paths.has(skill.path)) {
          fail(`duplicate skill path: ${skill.path}`);
        }
        paths.add(skill.path);

        const skillDir = path.join(root, skill.path);
        const skillFile = path.join(skillDir, 'SKILL.md');
        const skillReadme = path.join(skillDir, 'README.md');
        if (!fs.existsSync(skillDir) || !fs.statSync(skillDir).isDirectory()) {
          fail(`${skill.path} directory is missing`);
          continue;
        }

        if (!fs.existsSync(skillFile)) {
          fail(`${skill.path}/SKILL.md is missing`);
          continue;
        }

        if (!fs.existsSync(skillReadme)) {
          fail(`${skill.path}/README.md is missing`);
        }

        const frontmatter = parseFrontmatter(fs.readFileSync(skillFile, 'utf8'), skillFile);
        if (frontmatter.get('name') !== skill.name) {
          fail(`${skill.path}/SKILL.md frontmatter name must equal ${skill.name}`);
        }
        if (!frontmatter.get('description')) {
          fail(`${skill.path}/SKILL.md frontmatter description is required`);
        }
        if (!frontmatter.get('license')) {
          fail(`${skill.path}/SKILL.md frontmatter license is required`);
        }
        if (!frontmatter.get('metadata.author')) {
          fail(`${skill.path}/SKILL.md frontmatter metadata.author is required`);
        }
        const manifestVersion = frontmatter.get('metadata.version');
        if (!manifestVersion) {
          fail(`${skill.path}/SKILL.md frontmatter metadata.version is required`);
        }
        if (skill.version && manifestVersion && skill.version !== manifestVersion) {
          fail(`${skill.path} catalog version must match SKILL.md metadata.version`);
        }

        const marketplaceEntry = marketplace?.skills?.find((entry) => entry.name === skill.name);
        if (!marketplaceEntry) {
          fail(`.claude-plugin/marketplace.json is missing ${skill.name}`);
        } else {
          if (marketplaceEntry.source !== skill.path) {
            fail(`${skill.name} marketplace source must equal ${skill.path}`);
          }
          if (manifestVersion && marketplaceEntry.version !== manifestVersion) {
            fail(`${skill.name} marketplace version must match SKILL.md metadata.version`);
          }
        }

        const evalsPath = path.join(skillDir, 'evals', 'evals.json');
        if (fs.existsSync(evalsPath)) {
          const evals = readJson(evalsPath);
          if (evals) {
            if (evals.skill_name !== skill.name) {
              fail(`${skill.path}/evals/evals.json skill_name must equal ${skill.name}`);
            }
            if (!Array.isArray(evals.evals)) {
              fail(`${skill.path}/evals/evals.json must contain an evals array`);
            }
          }
        }
      }
    }
  }
}

if (errors.length > 0) {
  console.error('Skill repository validation failed:');
  for (const error of errors) {
    console.error(`- ${error}`);
  }
  process.exit(1);
}

console.log('Skill repository validation passed.');
