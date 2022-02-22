/** @type {import('@teckel.ts-internal/eslint-config/Types').IEslintConfig} */
const config = {
  env: { node: true ,
        browser: true,
        commonjs: true,
    es6: true
  },
  // extends: '@teckel.ts-internal/eslint-config',
  parser: '@typescript-eslint/parser',
  // "parser": "babel-eslint",
  parserOptions: {
    project: './tsconfig.lint.json',
    tsconfigRootDir: __dirname,
    ecmaVersion: 2017,
    ecmaFeatures: {
      jsx: true,
    "experimentalObjectRestSpread": true
    },
    sourceType: "module",
  },
};

module.exports = config;
