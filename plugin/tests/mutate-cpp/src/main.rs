//! `mutate-cpp sites --build DIR --unit FILE [--file FILE]`: prints the
//! mutation sites of FILE (default: the unit itself) as JSON lines.

use std::path::PathBuf;

use mutate_cpp::query;

fn arg(name: &str) -> Option<String> {
    let mut args = std::env::args().skip_while(|a| a != name);
    args.next()?;
    args.next()
}

fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_default();
    let result = match cmd.as_str() {
        "sites" => sites(),
        _ => Err("usage: mutate-cpp sites --build DIR --unit FILE [--file FILE]".into()),
    };
    if let Err(e) = result {
        eprintln!("mutate-cpp: {e}");
        std::process::exit(2);
    }
}

fn sites() -> Result<(), String> {
    let build = PathBuf::from(arg("--build").ok_or("--build is required")?);
    let unit = PathBuf::from(arg("--unit").ok_or("--unit is required")?);
    let file = arg("--file").map_or_else(|| unit.clone(), PathBuf::from);
    let (sites, skipped) = query::find(&build, &unit, &file)?;
    for s in &sites {
        println!(
            "{}",
            serde_json::json!({ "line": s.line, "col": s.col, "kind": format!("{:?}", s.kind), "from": s.from, "to": s.to })
        );
    }
    for s in &skipped {
        eprintln!("skipped: {s}");
    }
    Ok(())
}
