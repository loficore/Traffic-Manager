import { render } from 'preact';
import { App } from './App';
import './app.css';

// 将根组件挂载到 #app 容器
render(<App />, document.getElementById('app')!);
