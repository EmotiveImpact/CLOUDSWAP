fn main() {
    let rows = cloudswap_core::scenarios();
    let ok = rows.iter().all(|(_, passed)| *passed);
    let scenarios = rows.iter().map(|(name, passed)| format!("{{\"name\":\"{name}\",\"passed\":{passed}}}")).collect::<Vec<_>>().join(",");
    println!("{{\"mode\":\"simulation\",\"system_swap_active\":false,\"passed\":{ok},\"scenarios\":[{scenarios}]}}");
    if !ok { std::process::exit(1); }
}
