import common
import gleam/dict
import gleam/http.{Post}
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import kirala/bbmarkdown/html_renderer
import server/database
import server/error
import server/github
import server/html as app_html
import server/npm
import server/web
import wisp.{type Request}

pub fn handle_request(
  req: Request,
  make_context: fn() -> web.Context,
) -> wisp.Response {
  let context = make_context()
  use request <- web.middleware(req, context)

  case wisp.path_segments(request) {
    ["process"] -> get_processed_dependencies(request, context)
    _ -> app_html.serve_html()
  }
}

fn get_processed_dependencies(
  req: Request,
  context: web.Context,
) -> wisp.Response {
  use <- wisp.require_method(req, Post)
  use json <- wisp.require_json(req)

  let decoded_deps = common.decode_dependencies(json)

  case decoded_deps {
    Ok(client_dependencies) ->
      processed_dependencies_handler(client_dependencies, context.db)
    Error(_) -> wisp.unprocessable_entity()
  }
}

fn processed_dependencies_handler(
  client_dependencies: List(common.ClientDependency),
  db: database.Connection,
) {
  let releases_from_cache = get_releases_from_cache(client_dependencies, db)
  let dependencies_not_in_cache =
    get_deps_not_in_cache(client_dependencies, releases_from_cache)

  let cache_dependecy_map =
    common.dependency_map_from_releases(releases_from_cache)

  case dependencies_not_in_cache {
    [] -> {
      wisp.json_response(common.encode_dependency_map(cache_dependecy_map), 200)
    }

    rest_dependencies -> {
      let external_processed_deps =
        get_external_processed_dependencies(rest_dependencies)

      let insertable_releases =
        common.releases_from_processed_dependency(external_processed_deps)
      database.insert_releases(db, insertable_releases)

      let external_dependency_map =
        common.dependency_map_from_processed_dependencies(with_html_body(
          external_processed_deps,
        ))

      let combined = dict.merge(cache_dependecy_map, external_dependency_map)
      wisp.json_response(common.encode_dependency_map(combined), 200)
    }
  }
}

fn get_releases_from_cache(
  client_dependencies: List(common.ClientDependency),
  db: database.Connection,
) -> List(common.Release) {
  client_dependencies
  |> list.try_map(fn(dependency) { database.get_releases(db, dependency) })
  |> result.unwrap([])
  |> list.flatten
}

fn get_deps_not_in_cache(
  client_dependencies: List(common.ClientDependency),
  releases: List(common.Release),
) -> List(common.ClientDependency) {
  let cache_keys =
    list.map(releases, fn(release) { release.dependency_name })
    |> set.from_list

  let dependencies_not_in_cache =
    list.filter(client_dependencies, fn(dependency) {
      !set.contains(cache_keys, dependency.name)
    })
  dependencies_not_in_cache
}

fn get_external_processed_dependencies(
  dependencies: List(common.ClientDependency),
) -> List(common.ProcessedDependency) {
  let separated_packages =
    dependencies
    |> list.map(npm.get_package_meta)
    |> separate_packages()

  let processed_dependencies =
    separated_packages.found_packages
    |> list.map(fn(package) {
      package
      |> github.get_releases_for_npm_package()
      |> processed_dependency_from_releases(package.dependency_name)
    })

  let not_found_dependencies =
    list.map(separated_packages.not_found_packages, common.as_not_found)

  list.append(processed_dependencies, not_found_dependencies)
}

fn processed_dependency_from_releases(
  releases: Result(List(common.Release), error.Error),
  dependency_name: String,
) -> common.ProcessedDependency {
  case releases {
    Ok(releases_) -> {
      case releases_ {
        [] -> common.as_no_releases(dependency_name)
        _ -> common.as_has_releases(dependency_name, releases_)
      }
    }

    Error(err) -> {
      case err {
        _ -> common.as_no_releases(dependency_name)
      }
    }
  }
}

type SeparatedPackages {
  SeparatedPackages(
    not_found_packages: List(String),
    found_packages: List(npm.PackageMeta),
  )
}

fn separate_packages(
  packages: List(Result(npm.PackageMeta, error.Error)),
) -> SeparatedPackages {
  list.fold(
    packages,
    SeparatedPackages(not_found_packages: [], found_packages: []),
    fn(acc, result) {
      case result {
        Ok(meta) ->
          SeparatedPackages(..acc, found_packages: [meta, ..acc.found_packages])
        Error(err) -> {
          case err {
            error.Http(error.NotFound(_, name)) -> {
              SeparatedPackages(
                ..acc,
                not_found_packages: [name, ..acc.not_found_packages],
              )
            }
            _ -> acc
          }
        }
      }
    },
  )
}

// before sending the releases fetched from github to client
// we want to turn the markdown release body into a html string
fn with_html_body(
  processed_dependencies: List(common.ProcessedDependency),
) -> List(common.ProcessedDependency) {
  list.map(processed_dependencies, fn(dependency) {
    case dependency {
      common.HasReleases(_, name, releases) -> {
        common.as_has_releases(name, do_html_body(releases))
      }
      common.NoReleases(_, name) -> common.as_no_releases(name)
      common.NotFound(_, name) -> common.as_not_found(name)
    }
  })
}

fn do_html_body(releases: List(common.Release)) -> List(common.Release) {
  list.map(releases, fn(release) {
    let html_body = html_renderer.convert(option.unwrap(release.body, ""))
    common.Release(..release, body: option.Some(html_body))
  })
}
