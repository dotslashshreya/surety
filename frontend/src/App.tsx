import { CuratorPanel } from "./components/CuratorPanel";
import { DemoBar } from "./components/DemoBar";
import { DepositPanel } from "./components/DepositPanel";
import { EventLog } from "./components/EventLog";
import { Header } from "./components/Header";
import { useSim } from "./model/useSim";

const SPEED = 20; // simulated seconds per real second: a 30-minute epoch plays in 90 seconds

export default function App() {
  const [sim, dispatch] = useSim(SPEED);
  return (
    <div className="app">
      <Header sim={sim} speed={SPEED} />
      <main className="layout">
        <CuratorPanel sim={sim} />
        <DepositPanel sim={sim} dispatch={dispatch} />
        <EventLog sim={sim} />
      </main>
      <DemoBar dispatch={dispatch} />
      <footer className="footer">
        <a href="https://github.com/dotslashshreya/surety">Code on GitHub</a>
        <a href="https://github.com/dotslashshreya/surety#gas">Gas table</a>
        <a href="https://github.com/dotslashshreya/surety/blob/main/audit/README.md">Static analysis</a>
      </footer>
    </div>
  );
}
