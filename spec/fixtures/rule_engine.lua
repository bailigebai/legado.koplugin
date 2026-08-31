return {
    html = [[
<html><body>
  <section id="books" class="panel featured" data-role="main-area">
    <a class="book primary" href="/book/1" data-kind="fiction-one"><span class="title">Alpha</span><em>New</em></a>
    <a class="book secondary" href="book/2" data-kind="fiction-two"><span class="title">Beta</span></a>
  </section>
  <p class="note">Hello <b>World</b> Tail</p>
  <div class="twins"><span>One</span><em>Middle</em><span>Two</span></div>
  <ul><li>A</li><li class="special">B</li><li>C</li></ul>
  <img id="cover" src="../images/cover.jpg" data-token="cover-token" />
  <meta id="summary" content="Synthetic summary" />
</body></html>
]],
    json = [[{"store":{"books":[{"title":"A","price":5,"active":true},{"title":"B","price":15,"active":false}],"odd.key":{"value":"quoted"}},"a||b":"kept","joined":"x&&y","quote'key":"escaped"}]],
    base_url = "https://example.test/library/index.html",
}
