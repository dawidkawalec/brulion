/* Brulion landing: header, mobile menu, the notebook demo of the hero, the use case tabs, the
   "how it works" steps and the measurements rail. No network, no storage, no cookies. */
(function () {
  'use strict'

  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)')
  var hasIO = 'IntersectionObserver' in window

  /* Header: transparent over the hero, dark glass once the page scrolls. */
  var top = document.querySelector('[data-top]')
  function onScroll() { top.classList.toggle('is-scrolled', window.scrollY > 24) }
  if (top) {
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
  }

  /* Mobile menu */
  var burger = document.querySelector('[data-burger]')
  var menu = document.getElementById('menu')
  if (burger && menu) {
    var setMenu = function (open) {
      burger.setAttribute('aria-expanded', String(open))
      menu.classList.toggle('is-open', open)
      if (open) top.classList.add('is-scrolled')
      else onScroll()
    }
    burger.addEventListener('click', function () { setMenu(burger.getAttribute('aria-expanded') !== 'true') })
    menu.addEventListener('click', function (e) { if (e.target.closest('a')) setMenu(false) })
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') setMenu(false) })
  }

  /* Use case tabs: the tab picks the screenshot on the stage and the copy beside it. */
  var tablist = document.querySelector('[data-tabs]')
  if (tablist) {
    var tabs = Array.prototype.slice.call(tablist.querySelectorAll('[role="tab"]'))
    var views = document.querySelectorAll('[data-view]')
    var select = function (index, focus) {
      tabs.forEach(function (tab, i) {
        var on = i === index
        tab.setAttribute('aria-selected', String(on))
        tab.tabIndex = on ? 0 : -1
        document.getElementById(tab.getAttribute('aria-controls')).hidden = !on
        if (on && focus) tab.focus()
      })
      views.forEach(function (img) { img.hidden = Number(img.getAttribute('data-view')) !== index })
    }
    tabs.forEach(function (tab, i) {
      tab.addEventListener('click', function () { select(i, false) })
      tab.addEventListener('keydown', function (e) {
        var n = tabs.length
        if (e.key === 'ArrowRight') { e.preventDefault(); select((i + 1) % n, true) }
        if (e.key === 'ArrowLeft') { e.preventDefault(); select((i - 1 + n) % n, true) }
        if (e.key === 'Home') { e.preventDefault(); select(0, true) }
        if (e.key === 'End') { e.preventDefault(); select(n - 1, true) }
      })
    })
  }

  /* How it works: the steps drive the compose window. They advance by themselves while the
     section is on screen, until the visitor picks one. */
  var how = document.querySelector('[data-how]')
  if (how) {
    var compose = how.querySelector('[data-compose]')
    var stepButtons = Array.prototype.slice.call(how.querySelectorAll('[data-go]'))
    var current = 1
    var timer = 0
    var manual = false
    var show = function (n) {
      current = n
      compose.setAttribute('data-step', String(n))
      stepButtons.forEach(function (b) { b.setAttribute('aria-pressed', String(Number(b.getAttribute('data-go')) === n)) })
    }
    var stop = function () { clearInterval(timer); timer = 0 }
    var start = function () {
      if (manual || reduce.matches || timer) return
      timer = setInterval(function () { show(current % 4 + 1) }, 2600)
    }
    stepButtons.forEach(function (b) {
      b.addEventListener('click', function () {
        manual = true
        stop()
        show(Number(b.getAttribute('data-go')))
      })
    })
    if (reduce.matches) show(4)
    else if (hasIO) {
      new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { if (e.isIntersecting) start(); else stop() })
      }, { threshold: 0.35 }).observe(how)
    }
  }

  /* Measurements rail: the arrows scroll by one card. */
  var rail = document.querySelector('[data-rail]')
  if (rail) {
    var track = rail.querySelector('[data-rail-track]')
    var prev = rail.querySelector('[data-rail-prev]')
    var next = rail.querySelector('[data-rail-next]')
    var step = function () {
      var card = track.querySelector('li')
      return card ? card.getBoundingClientRect().width + 20 : 360
    }
    var update = function () {
      prev.disabled = track.scrollLeft <= 4
      next.disabled = track.scrollLeft + track.clientWidth >= track.scrollWidth - 4
    }
    prev.addEventListener('click', function () { track.scrollBy({ left: -step(), behavior: reduce.matches ? 'auto' : 'smooth' }) })
    next.addEventListener('click', function () { track.scrollBy({ left: step(), behavior: reduce.matches ? 'auto' : 'smooth' }) })
    track.addEventListener('scroll', update, { passive: true })
    window.addEventListener('resize', update)
    update()
  }

  /* The notebook demo. Each token is [raw] (kept as is), [raw, clean] (same word with
     punctuation, a capital or a Polish letter) or [raw, null] (a filler the correction drops).
     Like Brulion's word guard, the clean text never swaps a word for another one. */
  var EXAMPLES = [
    [['yyy', null], ['panie', 'Panie'], ['tomaszu', 'Tomaszu,'], ['przesyłam'], ['poprawioną'], ['ofertę'], ['na'],
      ['stronę', 'stronę.'], ['wycena', 'Wycena'], ['się'], ['nie'], ['zmieniła', 'zmieniła,'], ['a'], ['termin'],
      ['przesuwamy'], ['na'], ['piątek', 'piątek.'], ['no', null], ['proszę', 'Proszę'], ['o'], ['potwierdzenie', 'potwierdzenie.']],
    [['eee', null], ['kochanie', 'Kochanie,'], ['odbiorę'], ['dzieci'], ['ze'], ['szkoły'], ['o'], ['piętnastej', 'piętnastej,'],
      ['a'], ['ty'], ['kup'], ['chleb'], ['i'], ['mleko', 'mleko,'], ['yyy', null], ['dobrze', 'dobrze?']],
    [['no', null], ['dobra', 'Dobra,'], ['po'], ['spotkaniu'], ['z'], ['klientem', 'klientem:'], ['kampania'], ['rusza'], ['w'],
      ['poniedziałek', 'poniedziałek,'], ['budżet'], ['zostaje'], ['bez'], ['zmian', 'zmian.'], ['eee', null],
      ['tomek', 'Tomek'], ['przygotuje'], ['raport'], ['do'], ['środy', 'środy.']]
  ]

  var demo = document.getElementById('demo')
  if (!demo) return

  var rough = demo.querySelector('[data-rough]')
  var clean = demo.querySelector('[data-clean]')
  var summary = demo.querySelector('[data-summary]')
  var widget = demo.querySelector('[data-widget]')
  var wave = demo.querySelector('[data-wave]')
  var status = demo.querySelector('[data-status]')
  var exampleTabs = demo.querySelectorAll('[data-example]')
  var replay = demo.querySelector('[data-replay]')

  var BARS = 22
  var bars = []
  for (var b = 0; b < BARS; b++) {
    var bar = document.createElement('i')
    bar.style.setProperty('--i', String(b))
    wave.appendChild(bar)
    bars.push(bar)
  }

  var example = 0
  var run = 0
  var timers = []

  function later(fn, ms) { timers.push(setTimeout(fn, ms)) }
  function every(fn, ms) { var id = setInterval(fn, ms); timers.push(id); return id }
  function stopAll() {
    timers.forEach(function (id) { clearTimeout(id); clearInterval(id) })
    timers = []
  }

  function plural(n, one, few, many) {
    if (n === 1) return one
    var d = n % 10
    var h = n % 100
    return d >= 2 && d <= 4 && (h < 12 || h > 14) ? few : many
  }

  function text(s) { return document.createTextNode(s) }
  function el(tag, cls, content) {
    var e = document.createElement(tag)
    if (cls) e.className = cls
    if (content != null) e.textContent = content
    return e
  }

  /* Builds the whole example at once, words invisible, so the sheet never changes height while
     it plays. Returns the counts for the summary line. */
  function render(index) {
    var tokens = EXAMPLES[index]
    var counts = { punct: 0, caps: 0, fillers: 0 }
    var cleanWords = []
    rough.textContent = ''
    tokens.forEach(function (tok, i) {
      var raw = tok[0]
      var fixed = tok.length > 1 ? tok[1] : raw
      var w = el('span', 'w')
      if (fixed === null) {
        w.classList.add('w--filler')
        w.textContent = raw
        counts.fillers += 1
      } else {
        cleanWords.push(fixed)
        for (var c = 0; c < fixed.length; c++) {
          if (c >= raw.length) {
            w.appendChild(el('span', 'p', fixed[c]))
            counts.punct += 1
          } else if (fixed[c] !== raw[c]) {
            var ch = el('span', 'c', raw[c])
            ch.setAttribute('data-to', fixed[c])
            w.appendChild(ch)
            counts.caps += 1
          } else {
            w.appendChild(text(raw[c]))
          }
        }
      }
      rough.appendChild(w)
      if (i < tokens.length - 1) rough.appendChild(text(' '))
    })
    clean.textContent = ''
    clean.classList.remove('is-pasted')
    clean.appendChild(el('span', 't', cleanWords.join(' ')))
    summary.textContent = ''
    return counts
  }

  function summaryText(k) {
    return 'Bielik dodał ' + k.punct + ' ' + plural(k.punct, 'znak interpunkcyjny', 'znaki interpunkcyjne', 'znaków interpunkcyjnych') +
      ' i ' + k.caps + ' ' + plural(k.caps, 'wielką literę', 'wielkie litery', 'wielkich liter') +
      ', a wyrzucił ' + k.fillers + ' ' + plural(k.fillers, 'wypełniacz', 'wypełniacze', 'wypełniaczy') +
      '. Twoich słów nie zmienił.'
  }

  function setWidget(state, label) {
    widget.setAttribute('data-state', state)
    status.textContent = label
    if (state !== 'rec') bars.forEach(function (bar) { bar.style.height = '' })
  }

  function fixOne(w) {
    if (w.classList.contains('w--filler')) w.classList.add('is-struck')
    w.querySelectorAll('.c').forEach(function (c) {
      c.textContent = c.getAttribute('data-to')
      c.classList.add('is-fixed')
    })
    w.querySelectorAll('.p').forEach(function (p) { p.classList.add('is-fixed') })
  }

  function needsFix(w) {
    return w.classList.contains('w--filler') || w.querySelector('.c, .p')
  }

  function showFinal(index) {
    stopAll()
    run += 1
    var counts = render(index)
    rough.querySelectorAll('.w').forEach(function (w) {
      w.classList.add('is-heard')
      fixOne(w)
    })
    clean.classList.add('is-pasted')
    summary.textContent = summaryText(counts)
    setWidget('done', 'Poprawione w 1,4 s')
  }

  function play(index) {
    if (reduce.matches) { showFinal(index); return }
    stopAll()
    var mine = ++run
    var counts = render(index)
    var words = Array.prototype.slice.call(rough.querySelectorAll('.w'))
    demo.setAttribute('aria-busy', 'true')

    /* 1. Speaking: words are "heard" one by one, the widget records. */
    var started = performance.now()
    setWidget('rec', '00:00')
    every(function () {
      var level = 0.35 + Math.random() * 0.65
      bars.forEach(function (bar, i) {
        var env = Math.pow(Math.sin(Math.PI * (i + 0.5) / BARS), 0.8)
        bar.style.height = (3 + Math.round(env * level * (6 + Math.random() * 16))) + 'px'
      })
      var s = Math.floor((performance.now() - started) / 1000)
      status.textContent = '00:' + (s < 10 ? '0' : '') + s
    }, 110)

    var at = 300
    words.forEach(function (w) {
      at += 140 + w.textContent.length * 22
      later(function () { if (mine === run) w.classList.add('is-heard') }, at)
    })

    /* 2. Bielik corrects (the median measured correction time). */
    at += 450
    later(function () {
      if (mine !== run) return
      stopAll()
      setWidget('think', 'Bielik poprawia')
      var pen = 1400
      var marked = words.filter(needsFix)
      marked.forEach(function (w, i) {
        later(function () { if (mine === run) fixOne(w) }, pen + i * 110)
      })
      later(function () { if (mine === run) setWidget('done', 'Poprawione w 1,4 s') }, pen)
      /* 3. The clean text is pasted at the cursor, whole, as the app does. */
      later(function () {
        if (mine !== run) return
        clean.classList.add('is-pasted')
        summary.textContent = summaryText(counts)
        demo.removeAttribute('aria-busy')
      }, pen + marked.length * 110 + 250)
    }, at)
  }

  function choose(index) {
    example = index
    exampleTabs.forEach(function (t) { t.setAttribute('aria-pressed', String(Number(t.getAttribute('data-example')) === index)) })
    play(index)
  }

  exampleTabs.forEach(function (t) {
    t.addEventListener('click', function () { choose(Number(t.getAttribute('data-example'))) })
  })
  replay.addEventListener('click', function () { play(example) })

  /* Plays once when the sheet comes into view; until then it shows the finished example. */
  showFinal(0)
  if (!reduce.matches && hasIO) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          io.disconnect()
          play(example)
        }
      })
    }, { threshold: 0.45 })
    io.observe(demo)
  }
})()
