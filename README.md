### gleam-whats-changed

- port of my existing whats-changed app to gleam for fun!
- [wisp](https://github.com/gleam-wisp/wisp) backend
- [lustre](https://github.com/lustre-labs/lustre) front-end

Paste a `package.json` and get back a list of releases for each dependency that are greater than the provided version.

Backed by a SQLite DB which has releases for some dependencies to try make requests faster. If a dependency isn't in the cache, requests will slow down considerably (some package.json's have taken like 40 seconds for me) as I have to fetch the data from NPM and then paginate Github for the releases.. but they are written into DB as we go.

Caveat: until I setup a litefs volume on fly.io the sqlite database is not present on the deployed version, as such.. requests will be much much slower as it has to rawdog via npm/github to get release information
