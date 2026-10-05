// Claude's bundled Node runtime imports this entry instead of executing it as
// require.main. Start explicitly; index.js remains safe to import in tests.
require('./index.js').startStdio();
